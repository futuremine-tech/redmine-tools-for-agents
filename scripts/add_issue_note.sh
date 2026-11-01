#!/usr/bin/env bash
#
# Redmineの要件チケットにコメントを追記する（ステータスは変更しない）。
# 使い方: add_issue_note.sh [--allow-closed] <issue_id> <note_file>
#   --allow-closed  対象チケットが終了扱い（Redmineのステータス設定で「終了したチケット」）でも
#                    投稿する。省略時、終了扱いのチケットへの投稿はエラーで止める

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

usage() {
    echo "使い方: add_issue_note.sh [--allow-closed] <issue_id> <note_file>" >&2
    exit 1
}

ALLOW_CLOSED=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --allow-closed)
            ALLOW_CLOSED="1"
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

[ "${#POSITIONAL[@]}" -eq 2 ] || usage

ISSUE_ID="${POSITIONAL[0]}"
NOTE_FILE="${POSITIONAL[1]}"

if [ ! -f "$NOTE_FILE" ]; then
    echo "コメントファイルが見つかりません: $NOTE_FILE" >&2
    exit 1
fi

if [ "$(is_issue_closed "$ISSUE_ID")" = "true" ] && [ -z "$ALLOW_CLOSED" ]; then
    echo "チケット #$ISSUE_ID は終了扱いのステータスです。終了済みのチケットへのコメント追記は" >&2
    echo "通常、新しいチケットとして切り出すべきです。意図して追記する場合は --allow-closed を" >&2
    echo "付けて再実行してください。" >&2
    exit 1
fi

check_bare_refs "$NOTE_FILE"

PAYLOAD="$(jq -n \
    --rawfile notes "$NOTE_FILE" \
    '{issue: {notes: $notes}}')"

api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID にコメントを追記しました。"
