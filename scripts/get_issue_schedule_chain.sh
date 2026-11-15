#!/usr/bin/env bash
#
# チケットのスケジュール上の依存チェーン（precedes/follows）を一括でたどって一覧表示する。
# 使い方: get_issue_schedule_chain.sh <issue_id>
#
# 起点チケットから、precedes/follows関連を両方向（先行する・後続するの両方）に再帰的にたどり、
# 同一チェーンに属するチケット一覧を出力する。起点がチェーンの途中の場合も、前後両方向をたどって
# 一覧に含める。分岐（1つのチケットが複数のチケットに先行/後続する）がある場合もすべてたどる
# （最長チェーン・クリティカルパスの自動算出は行わない）。他の関連タイプ（relates・copied_to等）
# はたどらない。
# Redmineの関連APIには再帰取得の手段が無いため、チケット1件ごとにAPI呼び出しを行う
# （get_issue_tree.shのような1回で済む再帰取得はできない）。件数の上限は設けていない。
#
# 出力はTSV形式（1行1チケット。ID・プロジェクト識別子・件名・ステータス・開始日・期日・
# 稼働日数・（実開始日・実終了日。存在するインスタンスのみ）・発見元チケットID・関連タイプ）。
# 発見元チケットID・関連タイプは起点チケット自身では空欄になる。
# precedes/followsの日付連動自体はRedmine側が自動的に行う（実機確認済み。先行チケットの
# 期日を延ばすと、後続チケットの開始日・期日は土日を考慮して自動的にずらされる）ため、本スクリプト
# では日付の整合性チェックは行わない。稼働日数（土日を除く開始日・期日間の日数）を示すことで、
# 各チケットに割り当てられている期間が妥当かどうかの判断材料とする。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_issue_schedule_chain.sh <issue_id>" >&2
    exit 1
fi

START_ID="$1"

relation_type_label_for() {
    case "$1" in
        precedes) echo "先行する" ;;
        follows) echo "後続する" ;;
        *) echo "$1" ;;
    esac
}

is_visited() {
    local target="$1"
    local v
    for v in "${VISITED_IDS[@]}"; do
        [ "$v" = "$target" ] && return 0
    done
    return 1
}

# 対象インスタンスにactual_start_date/actual_due_dateが存在するかを、起点チケットの
# レスポンスで一度だけ判定し、以降の全行に対して同じ扱いにする（RTS #110の方式を踏襲）。
FIRST_ISSUE_JSON="$(api_get "$REDMINE_URL/issues/$START_ID.json?include=relations")"
INCLUDE_ACTUAL=false
if echo "$FIRST_ISSUE_JSON" | jq -e '.issue | has("actual_start_date")' > /dev/null; then
    INCLUDE_ACTUAL=true
fi

declare -a QUEUE=("$START_ID")
declare -a VISITED_IDS=()
declare -A VIA_ID=()
declare -A VIA_TYPE=()
declare -A ISSUE_JSON_CACHE=()
ISSUE_JSON_CACHE["$START_ID"]="$FIRST_ISSUE_JSON"

QUEUE_INDEX=0
while [ "$QUEUE_INDEX" -lt "${#QUEUE[@]}" ]; do
    CURRENT_ID="${QUEUE[$QUEUE_INDEX]}"
    QUEUE_INDEX=$((QUEUE_INDEX + 1))

    if is_visited "$CURRENT_ID"; then
        continue
    fi
    VISITED_IDS+=("$CURRENT_ID")

    ISSUE_JSON="${ISSUE_JSON_CACHE[$CURRENT_ID]:-}"
    if [ -z "$ISSUE_JSON" ]; then
        ISSUE_JSON="$(api_get "$REDMINE_URL/issues/$CURRENT_ID.json?include=relations")"
    fi

    MY_START="$(echo "$ISSUE_JSON" | jq -r '.issue.start_date // ""')"
    MY_DUE="$(echo "$ISSUE_JSON" | jq -r '.issue.due_date // ""')"
    WORKING_DAYS="$(calculate_working_days "$MY_START" "$MY_DUE")"

    VIA_ID_VALUE="${VIA_ID[$CURRENT_ID]:-}"
    VIA_LABEL=""
    if [ -n "$VIA_ID_VALUE" ]; then
        VIA_LABEL="$(relation_type_label_for "${VIA_TYPE[$CURRENT_ID]}")"
    fi

    echo "$ISSUE_JSON" | jq -r --argjson include_actual "$INCLUDE_ACTUAL" --arg working_days "$WORKING_DAYS" --arg via_id "$VIA_ID_VALUE" --arg via_label "$VIA_LABEL" '
        [.issue.id, (.issue.project.identifier // .issue.project.name // ""), .issue.subject, .issue.status.name, (.issue.start_date // ""), (.issue.due_date // ""), $working_days]
        + (if $include_actual then [(.issue.actual_start_date // ""), (.issue.actual_due_date // "")] else [] end)
        + [$via_id, $via_label]
        | @tsv
    ' | tr -d '\r'

    while IFS=$'\t' read -r other_id other_type; do
        [ -z "$other_id" ] && continue
        if ! is_visited "$other_id"; then
            QUEUE+=("$other_id")
            VIA_ID["$other_id"]="$CURRENT_ID"
            VIA_TYPE["$other_id"]="$other_type"
        fi
    done < <(extract_bidirectional_relations "$ISSUE_JSON" "$CURRENT_ID" "precedes" "follows")
done
