#!/usr/bin/env bash
#
# Redmineチケットのカテゴリを変更する。
# 使い方: update_issue_category.sh <issue_id> <category_name>
#   issue_id       対象チケットのID
#   category_name  チケットが属するプロジェクトに存在するカテゴリ名（完全一致）
#
# カテゴリが存在しない場合は自動作成せず、既存カテゴリ一覧を表示してエラー終了する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: update_issue_category.sh <issue_id> <category_name>" >&2
    exit 1
fi

ISSUE_ID="$1"
CATEGORY_NAME="$2"

if ! [[ "$ISSUE_ID" =~ ^[0-9]+$ ]]; then
    echo "チケットIDは数値で指定してください: $ISSUE_ID" >&2
    exit 1
fi

ISSUE_JSON="$(curl -sS -f \
    -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
    "$REDMINE_URL/issues/$ISSUE_ID.json")"
PROJECT_NUM_ID="$(echo "$ISSUE_JSON" | jq -r '.issue.project.id')"
PROJECT_ID="$(curl -sS -f \
    -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
    "$REDMINE_URL/projects/$PROJECT_NUM_ID.json" | jq -r '.project.identifier')"

CATEGORY_ID="$(resolve_category_id "$PROJECT_ID" "$CATEGORY_NAME")"

PAYLOAD="$(jq -n --argjson category_id "$CATEGORY_ID" '{issue: {category_id: $category_id}}')"

api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

echo "チケット #$ISSUE_ID のカテゴリを「$CATEGORY_NAME」に更新しました。"
