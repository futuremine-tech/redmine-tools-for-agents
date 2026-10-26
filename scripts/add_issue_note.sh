#!/usr/bin/env bash
#
# Redmineの要件チケットにコメントを追記する（ステータスは変更しない）。
# 使い方: add_issue_note.sh <issue_id> <note_file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: add_issue_note.sh <issue_id> <note_file>" >&2
    exit 1
fi

ISSUE_ID="$1"
NOTE_FILE="$2"

if [ ! -f "$NOTE_FILE" ]; then
    echo "コメントファイルが見つかりません: $NOTE_FILE" >&2
    exit 1
fi

check_bare_refs "$NOTE_FILE"

PAYLOAD="$(jq -n \
    --rawfile notes "$NOTE_FILE" \
    '{issue: {notes: $notes}}')"

api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID にコメントを追記しました。"
