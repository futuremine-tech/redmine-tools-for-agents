#!/usr/bin/env bash
#
# Redmineプロジェクトの対象バージョン一覧を表示する。
# 使い方: list_versions.sh <project_id>
#   project_id  Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でもよい。
#               ~/.config/redmine-project-map.json にエイリアスを設定している場合はそちらが優先される
#
# 出力は「<version_id><TAB><バージョン名><TAB>(<ステータス>)」の1行1バージョン。
# バージョンが無い場合は "(バージョンなし)" を表示する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: list_versions.sh <project_id>" >&2
    exit 1
fi

PROJECT_ID="$(resolve_project_identifier "$1")"
VERSIONS_JSON="$(fetch_versions_json "$PROJECT_ID")"

if [ "$(echo "$VERSIONS_JSON" | jq '.versions | length')" -eq 0 ]; then
    echo "(バージョンなし)"
else
    echo "$VERSIONS_JSON" | jq -r '.versions[] | "\(.id)\t\(.name)\t(\(.status))"'
fi
