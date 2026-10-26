#!/usr/bin/env bash
#
# Redmineの要件チケットのステータスを更新する。
# 使い方: update_issue_status.sh <issue_id> <status_name> [note_file]
#   issue_id    対象チケットのID
#   status_name Redmine側に存在するステータス名（例: 新規, 対応中, 対応完了）
#   note_file   ステータス変更と同時に追記するコメントを書いたテキストファイル（省略可）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "使い方: update_issue_status.sh <issue_id> <status_name> [note_file]" >&2
    exit 1
fi

ISSUE_ID="$1"
STATUS_NAME="$2"
NOTE_FILE="${3:-}"

STATUS_ID="$(resolve_status_id "$STATUS_NAME")"

if [ -n "$NOTE_FILE" ]; then
    if [ ! -f "$NOTE_FILE" ]; then
        echo "コメントファイルが見つかりません: $NOTE_FILE" >&2
        exit 1
    fi
    check_bare_refs "$NOTE_FILE"
    PAYLOAD="$(jq -n \
        --argjson status_id "$STATUS_ID" \
        --rawfile notes "$NOTE_FILE" \
        '{issue: {status_id: $status_id, notes: $notes}}')"
else
    PAYLOAD="$(jq -n \
        --argjson status_id "$STATUS_ID" \
        '{issue: {status_id: $status_id}}')"
fi

api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID のステータスを「$STATUS_NAME」に更新しました。"
