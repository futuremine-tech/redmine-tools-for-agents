#!/usr/bin/env bash
#
# 投稿済みのコメント（journal）の本文を書き換える。誤記修正等の保険的な手段であり、
# 投稿前の読み返しを代替するものではない。
# 使い方: edit_issue_note.sh <journal_id> <note_file>
#   journal_id  get_issue.sh のコメント履歴表示（[id=<journal_id> ...]）で特定する

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: edit_issue_note.sh <journal_id> <note_file>" >&2
    exit 1
fi

JOURNAL_ID="$1"
NOTE_FILE="$2"

if [ ! -f "$NOTE_FILE" ]; then
    echo "コメントファイルが見つかりません: $NOTE_FILE" >&2
    exit 1
fi

check_bare_refs "$NOTE_FILE"

PAYLOAD="$(jq -n \
    --rawfile notes "$NOTE_FILE" \
    '{journal: {notes: $notes}}')"

api_mutate PUT "$REDMINE_URL/journals/$JOURNAL_ID.json" "$PAYLOAD" > /dev/null

echo "コメント (journal #$JOURNAL_ID) を編集しました。"
