#!/usr/bin/env bash
#
# Redmineプロジェクトのチケットカテゴリ一覧を表示する。
# 使い方: list_categories.sh <project_id>
#   project_id  Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でもよい。
#               ~/.config/redmine-project-map.json にエイリアスを設定している場合はそちらが優先される
#
# 出力は「<category_id><TAB><カテゴリ名>」の1行1カテゴリ。カテゴリが無い場合は "(カテゴリなし)" を表示する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: list_categories.sh <project_id>" >&2
    exit 1
fi

PROJECT_ID="$(resolve_project_identifier "$1")"
CATEGORIES_JSON="$(fetch_categories_json "$PROJECT_ID")"

if [ "$(echo "$CATEGORIES_JSON" | jq '.issue_categories | length')" -eq 0 ]; then
    echo "(カテゴリなし)"
else
    echo "$CATEGORIES_JSON" | jq -r '.issue_categories[] | "\(.id)\t\(.name)"'
fi
