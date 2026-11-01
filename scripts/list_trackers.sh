#!/usr/bin/env bash
#
# Redmineプロジェクトで有効化されているトラッカー一覧を表示する。
# 使い方: list_trackers.sh <project_id>
#   project_id  Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でもよい。
#               ~/.config/redmine-project-map.json にエイリアスを設定している場合はそちらが優先される
#
# トラッカーはプロジェクトごとに有効化するものを選べるため、グローバルな一覧ではなく対象プロジェクトで
# 実際に有効なものだけを表示する。
# 出力は「<tracker_id><TAB><トラッカー名>」の1行1トラッカー。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: list_trackers.sh <project_id>" >&2
    exit 1
fi

PROJECT_ID="$(resolve_project_identifier "$1")"
PROJECT_JSON="$(fetch_project_trackers_json "$PROJECT_ID")"

if [ "$(echo "$PROJECT_JSON" | jq '.project.trackers | length')" -eq 0 ]; then
    echo "(有効なトラッカーなし)"
else
    echo "$PROJECT_JSON" | jq -r '.project.trackers[] | "\(.id)\t\(.name)"'
fi
