#!/usr/bin/env bash
#
# チケット本文（description）を書き換える。コメントの追記・編集と異なり、チケットの本文そのもの
# を直接上書きするため、呼び出し前に必ず変更内容（現在の本文との差分）をユーザーに提示し、承認を
# 得ること。承認を得ずに本スクリプトを呼び出さない。
# 使い方: edit_issue_description.sh <issue_id> <description_file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: edit_issue_description.sh <issue_id> <description_file>" >&2
    exit 1
fi

ISSUE_ID="$1"
DESCRIPTION_FILE="$2"

if [ ! -f "$DESCRIPTION_FILE" ]; then
    echo "本文ファイルが見つかりません: $DESCRIPTION_FILE" >&2
    exit 1
fi

check_bare_refs "$DESCRIPTION_FILE"

PAYLOAD="$(jq -n \
    --rawfile description "$DESCRIPTION_FILE" \
    '{issue: {description: $description}}')"

api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID の本文を更新しました。"
