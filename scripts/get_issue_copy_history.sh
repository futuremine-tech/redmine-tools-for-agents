#!/usr/bin/env bash
#
# チケットのコピー系譜（copied_to/copied_from）を一括でたどって一覧表示する。
# 使い方: get_issue_copy_history.sh <issue_id>
#
# 起点チケットから、copied_to/copied_from関連を両方向（コピー元・コピー先の両方）に
# 再帰的にたどり、同一系譜に属するチケット一覧を出力する。起点が系譜の途中（例: 前年度から
# コピーされ、かつ次年度へコピーされている）の場合も、前の代・後の代の両方をたどって一覧に
# 含める。他の関連タイプ（relates・blocks等）はたどらない。
# Redmineの関連APIには再帰取得の手段が無いため、チケット1件ごとにAPI呼び出しを行う
# （get_issue_tree.shのような1回で済む再帰取得はできない）。件数の上限は設けていない
# （コピー系譜は通常小規模なため）。
#
# 出力はTSV形式（1行1チケット。ID・プロジェクト識別子・件名・ステータス・発見元チケットID・
# 関連タイプ）。発見元チケットID・関連タイプは起点チケット自身では空欄になる。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_issue_copy_history.sh <issue_id>" >&2
    exit 1
fi

START_ID="$1"

relation_type_label_for() {
    case "$1" in
        copied_to) echo "コピー先" ;;
        copied_from) echo "コピー元" ;;
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

declare -a QUEUE=("$START_ID")
declare -a VISITED_IDS=()
declare -A VIA_ID=()
declare -A VIA_TYPE=()

QUEUE_INDEX=0
while [ "$QUEUE_INDEX" -lt "${#QUEUE[@]}" ]; do
    CURRENT_ID="${QUEUE[$QUEUE_INDEX]}"
    QUEUE_INDEX=$((QUEUE_INDEX + 1))

    if is_visited "$CURRENT_ID"; then
        continue
    fi
    VISITED_IDS+=("$CURRENT_ID")

    ISSUE_JSON="$(api_get "$REDMINE_URL/issues/$CURRENT_ID.json?include=relations")"

    VIA_ID_VALUE="${VIA_ID[$CURRENT_ID]:-}"
    VIA_LABEL=""
    if [ -n "$VIA_ID_VALUE" ]; then
        VIA_LABEL="$(relation_type_label_for "${VIA_TYPE[$CURRENT_ID]}")"
    fi

    echo "$ISSUE_JSON" | jq -r --arg via_id "$VIA_ID_VALUE" --arg via_label "$VIA_LABEL" '
        [.issue.id, (.issue.project.identifier // .issue.project.name // ""), .issue.subject, .issue.status.name, $via_id, $via_label]
        | @tsv
    ' | tr -d '\r'

    while IFS=$'\t' read -r other_id other_type; do
        [ -z "$other_id" ] && continue
        if ! is_visited "$other_id"; then
            QUEUE+=("$other_id")
            VIA_ID["$other_id"]="$CURRENT_ID"
            VIA_TYPE["$other_id"]="$other_type"
        fi
    done < <(extract_bidirectional_relations "$ISSUE_JSON" "$CURRENT_ID" "copied_to" "copied_from")
done
