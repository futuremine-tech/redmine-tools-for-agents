#!/usr/bin/env bash
#
# Redmineプロジェクトにチケットカテゴリを追加する。
# 使い方: create_category.sh <project_id> <category_name>
#   project_id     Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でもよい。
#                  ~/.config/redmine-project-map.json にエイリアスを設定している場合はそちらが優先される
#   category_name  追加するカテゴリ名
#
# 同名のカテゴリ（大文字・小文字の違いは無視）が既に存在する場合は、作成せずにエラー終了する。
# APIキーのユーザーに対象プロジェクトの「チケットのカテゴリの管理」権限が必要。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: create_category.sh <project_id> <category_name>" >&2
    exit 1
fi

CATEGORY_NAME="$2"
if [ -z "$CATEGORY_NAME" ]; then
    echo "カテゴリ名が空です。" >&2
    exit 1
fi

PROJECT_ID="$(resolve_project_identifier "$1")"
CATEGORIES_JSON="$(fetch_categories_json "$PROJECT_ID")"

EXISTING="$(echo "$CATEGORIES_JSON" | jq -r \
    --arg name "$CATEGORY_NAME" \
    '.issue_categories[] | select((.name | ascii_downcase) == ($name | ascii_downcase)) | .name' | head -n1)"

if [ -n "$EXISTING" ]; then
    echo "同名のカテゴリ '$EXISTING' がプロジェクト '$PROJECT_ID' に既に存在するため、作成しません。" >&2
    exit 1
fi

PAYLOAD="$(jq -n --arg name "$CATEGORY_NAME" '{issue_category: {name: $name}}')"

RESPONSE="$(api_mutate POST "$REDMINE_URL/projects/$PROJECT_ID/issue_categories.json" "$PAYLOAD")"

CATEGORY_ID="$(echo "$RESPONSE" | jq -r '.issue_category.id')"

echo "カテゴリを作成しました: $CATEGORY_NAME（id: $CATEGORY_ID, プロジェクト: $PROJECT_ID）"
