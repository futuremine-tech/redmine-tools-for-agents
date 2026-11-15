#!/usr/bin/env bash
#
# 起点チケットから、Redmineの親子関係（本文・コメント中のリンクではない）を再帰的にたどり、
# 子孫チケットの主要情報をまとめて表形式で出力する。本文・コメント中のリンクをたどる
# get_issue_recursive.sh とは別物であり、親子関係の階層構造を把握する目的で使う。
#
# 使い方: get_issue_tree.sh <parent_issue_id> [--max-depth <N>] [--count-only | --summary]
#   parent_issue_id  起点となるチケットのID
#   --max-depth      何階層先の子孫までたどるか（省略時は上限無し。子が無くなるまでたどる）
#   --count-only     詳細を取得せず、対象チケットの件数のみを表示する（1回のAPI呼び出しのみ。
#                     詳細取得前に規模を把握したい場合に使う）
#   --summary        詳細を取得せず、ID・件名・トラッカー名・親IDのみをまとめて表示する
#                     （1回のAPI呼び出しのみ。ステータス・日付等は含まれない）
#
# --count-only・--summary を指定しない場合（既定の詳細モード）は、チケット1件につき1回
# APIを呼び出すため、対象件数が多いと時間がかかる（件数の上限は設けていない。事前に
# --count-only・--summaryで規模を把握し、--max-depthで絞るか、時間がかかりそうならバック
# グラウンド実行を検討すること）。
# 出力は「ID・件名・ステータス・開始日・期日・(実開始日・実終了日)・親ID・関連チケット」の
# TSV1行1チケット（階層のインデント表示はしない。親ID列で親子関係を追う）。
# 実開始日・実終了日の列は、起点チケットのレスポンスにキーが存在する場合のみ含める
# （Lychee等が入っているインスタンス限定。list_instances.sh等と同様、見出し行は付けない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

usage() {
    echo "使い方: get_issue_tree.sh <parent_issue_id> [--max-depth <N>] [--count-only | --summary]" >&2
    exit 1
}

MODE="detail"
MAX_DEPTH=""
COUNT_ONLY_GIVEN=""
SUMMARY_GIVEN=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --max-depth)
            [ "$#" -ge 2 ] || usage
            MAX_DEPTH="$2"
            shift 2
            ;;
        --count-only)
            MODE="count"
            COUNT_ONLY_GIVEN=1
            shift
            ;;
        --summary)
            MODE="summary"
            SUMMARY_GIVEN=1
            shift
            ;;
        --*)
            echo "不明なオプション: $1" >&2
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [ -n "$COUNT_ONLY_GIVEN" ] && [ -n "$SUMMARY_GIVEN" ]; then
    echo "--count-only と --summary は同時に指定できません。" >&2
    exit 1
fi

[ "${#POSITIONAL[@]}" -eq 1 ] || usage

ROOT_ISSUE_ID="${POSITIONAL[0]}"

if [ -n "$MAX_DEPTH" ] && ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
    echo "max_depthは0以上の整数で指定してください: $MAX_DEPTH" >&2
    exit 1
fi

if [ "$MODE" != "detail" ]; then
    TREE_JSON="$(api_get "$REDMINE_URL/issues/$ROOT_ISSUE_ID.json?include=children")"
    ROWS="$(format_issue_tree_summary_rows "$TREE_JSON" "$MAX_DEPTH")"
    if [ "$MODE" = "count" ]; then
        echo "$ROWS" | wc -l
    else
        echo "$ROWS"
    fi
    exit 0
fi

declare -A VISITED
INCLUDE_ACTUAL=""

visit() {
    local issue_id="$1"
    local depth="$2"

    if [ -n "${VISITED[$issue_id]:-}" ]; then
        return
    fi
    VISITED[$issue_id]=1

    local issue_json
    issue_json="$(api_get "$REDMINE_URL/issues/$issue_id.json?include=children,relations")"

    if [ -z "$INCLUDE_ACTUAL" ]; then
        if echo "$issue_json" | jq -e '.issue | has("actual_start_date")' > /dev/null; then
            INCLUDE_ACTUAL=true
        else
            INCLUDE_ACTUAL=false
        fi
    fi

    format_issue_tree_row "$issue_json" "$INCLUDE_ACTUAL"

    if [ -n "$MAX_DEPTH" ] && [ "$depth" -ge "$MAX_DEPTH" ]; then
        return
    fi

    local child_id
    while read -r child_id; do
        [ -n "$child_id" ] || continue
        visit "$child_id" "$((depth + 1))"
    done < <(echo "$issue_json" | jq -r '.issue.children[]?.id // empty' | tr -d '\r')
}

visit "$ROOT_ISSUE_ID" 0
