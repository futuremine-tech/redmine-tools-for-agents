#!/usr/bin/env bash
#
# REDMINE_HUB_PROJECTのWikiにある、プロダクト識別子（プレフィックス）の一覧ページ
# （REDMINE_REQ_INDEX_PAGE）を更新する。
# 使い方: update_req_index.sh <content_file> <version> [comment]
#   content_file 更新後のページ本文を書いたテキストファイル
#   version      get_req_index.sh が表示した版番号（ページを新規作成する場合は new）。
#                取得後に他の更新が入っていた場合は、上書きせずにエラー終了する
#   comment      更新履歴に残すコメント（省略可）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY REDMINE_HUB_PROJECT REDMINE_REQ_INDEX_PAGE
require_jq

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "使い方: update_req_index.sh <content_file> <version> [comment]" >&2
    exit 1
fi

CONTENT_FILE="$1"
VERSION="$2"
COMMENT="${3:-}"

if [ ! -f "$CONTENT_FILE" ]; then
    echo "本文ファイルが見つかりません: $CONTENT_FILE" >&2
    exit 1
fi

if [ "$VERSION" != "new" ] && ! [[ "$VERSION" =~ ^[0-9]+$ ]]; then
    echo "版番号には数値または new を指定してください: $VERSION" >&2
    exit 1
fi

require_hub_project

PAGE_PATH="projects/$REDMINE_HUB_PROJECT/wiki/$(uri_encode "$REDMINE_REQ_INDEX_PAGE")"

if [ "$VERSION" = "new" ]; then
    PAYLOAD="$(jq -n \
        --rawfile text "$CONTENT_FILE" \
        --arg comments "$COMMENT" \
        '{wiki_page: {text: $text, comments: $comments}}')"
else
    PAYLOAD="$(jq -n \
        --rawfile text "$CONTENT_FILE" \
        --arg comments "$COMMENT" \
        --argjson version "$VERSION" \
        '{wiki_page: {text: $text, comments: $comments, version: $version}}')"
fi

api_mutate PUT "$REDMINE_URL/$PAGE_PATH.json" "$PAYLOAD" > /dev/null

echo "Wikiページ '$REDMINE_REQ_INDEX_PAGE'（プロジェクト '$REDMINE_HUB_PROJECT'）を更新しました。"
echo "$REDMINE_URL/$PAGE_PATH"
