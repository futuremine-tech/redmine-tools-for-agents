#!/usr/bin/env bash
#
# 既存のRedmineチケット同士を関連付ける（親子関係とは別の、Redmineの「関連チケット」機能）。
# 使い方: relate_issues.sh <issue_id_1> <issue_id_2> [--type <relation_type>]
#   issue_id_1      関連付け元のチケットID
#   issue_id_2      関連付け先のチケットID
#   --type          関連タイプ（省略時は relates）。指定可能な値と対応するRedmine UI上の表示:
#                      relates     関連している
#                      duplicates  重複する
#                      duplicated  重複される
#                      blocks      ブロックする
#                      blocked     ブロックされる
#                      precedes    先行する
#                      follows     後続する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

VALID_TYPES="relates duplicates duplicated blocks blocked precedes follows"

usage() {
    echo "使い方: relate_issues.sh <issue_id_1> <issue_id_2> [--type <relation_type>]" >&2
    exit 1
}

RELATION_TYPE="relates"
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

if ! echo " $VALID_TYPES " | grep -q " $RELATION_TYPE "; then
    echo "関連タイプ '$RELATION_TYPE' は指定できません。指定可能な値: $VALID_TYPES" >&2
    exit 1
fi

PAYLOAD="$(jq -n \
    --argjson issue_to_id "$ISSUE_ID_2" \
    --arg relation_type "$RELATION_TYPE" \
    '{relation: {issue_to_id: $issue_to_id, relation_type: $relation_type}}')"

api_mutate POST "$REDMINE_URL/issues/$ISSUE_ID_1/relations.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID_1 と #$ISSUE_ID_2 を関連付けました（関連タイプ: $RELATION_TYPE）。"
