#!/usr/bin/env bash
#
# relate_issues.shで設定した関連チケットを削除する。
# 使い方: delete_issue_relation.sh <issue_id_1> <issue_id_2> [--type <relation_type>]
#   issue_id_1   関連の一方のチケットID（順序は問わない）
#   issue_id_2   関連の他方のチケットID（順序は問わない）
#   --type       関連タイプ（省略可）。同じ2チケット間に複数タイプの関連が存在する場合に
#                どれを削除するか特定するために使う
#
# RedmineのREST APIには関連の更新（タイプの変更）は無いため、タイプを変更する場合は
# 本スクリプトで削除してからrelate_issues.shで新しいタイプで作り直す。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

usage() {
    echo "使い方: delete_issue_relation.sh <issue_id_1> <issue_id_2> [--type <relation_type>]" >&2
    exit 1
}

RELATION_TYPE=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --type)
            [ "$#" -ge 2 ] || usage
            RELATION_TYPE="$2"
            shift 2
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

[ "${#POSITIONAL[@]}" -eq 2 ] || usage

ISSUE_ID_1="${POSITIONAL[0]}"
ISSUE_ID_2="${POSITIONAL[1]}"

if ! [[ "$ISSUE_ID_1" =~ ^[0-9]+$ ]] || ! [[ "$ISSUE_ID_2" =~ ^[0-9]+$ ]]; then
    echo "チケットIDは数値で指定してください: $ISSUE_ID_1 / $ISSUE_ID_2" >&2
    exit 1
fi

RELATIONS_JSON="$(curl -sS -f \
    -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
    "$REDMINE_URL/issues/$ISSUE_ID_1.json?include=relations" | jq -c '.issue.relations // []')"

MATCHES="$(echo "$RELATIONS_JSON" | jq -c \
    --argjson a "$ISSUE_ID_1" --argjson b "$ISSUE_ID_2" --arg type "$RELATION_TYPE" '
    .[] | select(
        ((.issue_id == $a and .issue_to_id == $b) or (.issue_id == $b and .issue_to_id == $a))
        and ($type == "" or .relation_type == $type)
    )')"

MATCH_COUNT="$(echo "$MATCHES" | jq -s 'length')"

if [ "$MATCH_COUNT" -eq 0 ]; then
    echo "チケット #$ISSUE_ID_1 と #$ISSUE_ID_2 の間に${RELATION_TYPE:+「$RELATION_TYPE」}関連が見つかりません。既存の関連:" >&2
    echo "$RELATIONS_JSON" | jq -r '.[] | "- id=\(.id) \(.issue_id)->\(.issue_to_id) (\(.relation_type))"' >&2
    exit 1
fi

if [ "$MATCH_COUNT" -gt 1 ]; then
    echo "チケット #$ISSUE_ID_1 と #$ISSUE_ID_2 の間に複数の関連が見つかりました。--typeで指定してください:" >&2
    echo "$MATCHES" | jq -r '"- id=\(.id) \(.issue_id)->\(.issue_to_id) (\(.relation_type))"' >&2
    exit 1
fi

RELATION_ID="$(echo "$MATCHES" | jq -r '.id')"
RELATION_TYPE_FOUND="$(echo "$MATCHES" | jq -r '.relation_type')"

api_mutate DELETE "$REDMINE_URL/relations/$RELATION_ID.json" "" > /dev/null

echo "チケット #$ISSUE_ID_1 と #$ISSUE_ID_2 の関連（関連タイプ: $RELATION_TYPE_FOUND）を削除しました。"
