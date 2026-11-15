#!/usr/bin/env bash
#
# Redmineチケットの対象バージョンを変更する。
# 使い方: update_issue_version.sh <issue_id> <version_name>
#   issue_id      対象チケットのID。カンマ区切りで複数指定できる（例: 101,102,103）
#   version_name  チケットが属するプロジェクトに存在する対象バージョン名（完全一致）
#
# バージョンが存在しない場合は自動作成せず、既存バージョン一覧を表示してエラー終了する。
# 複数ID指定時は1件ずつ更新し、一部が失敗しても他のIDの更新は続行したうえで、失敗したIDを
# 最後にまとめて報告する（終了コード1）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

if [ "$#" -ne 2 ]; then
    echo "使い方: update_issue_version.sh <issue_id> <version_name>" >&2
    exit 1
fi

ISSUE_IDS_RAW="$1"
VERSION_NAME="$2"

update_one_issue_version() {
    local ISSUE_ID="$1"

    if ! [[ "$ISSUE_ID" =~ ^[0-9]+$ ]]; then
        echo "チケットIDは数値で指定してください: $ISSUE_ID" >&2
        exit 1
    fi

    local ISSUE_JSON PROJECT_NUM_ID PROJECT_ID VERSION_ID PAYLOAD
    ISSUE_JSON="$(api_get "$REDMINE_URL/issues/$ISSUE_ID.json")"
    PROJECT_NUM_ID="$(echo "$ISSUE_JSON" | jq -r '.issue.project.id')"
    PROJECT_ID="$(api_get "$REDMINE_URL/projects/$PROJECT_NUM_ID.json" | jq -r '.project.identifier')"

    VERSION_ID="$(resolve_version_id "$PROJECT_ID" "$VERSION_NAME")"

    PAYLOAD="$(jq -n --argjson fixed_version_id "$VERSION_ID" '{issue: {fixed_version_id: $fixed_version_id}}')"

    api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

    echo "チケット #$ISSUE_ID の対象バージョンを「$VERSION_NAME」に更新しました。"
}

run_for_each_issue_id "$ISSUE_IDS_RAW" update_one_issue_version
