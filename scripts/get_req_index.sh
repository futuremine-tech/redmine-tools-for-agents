#!/usr/bin/env bash
#
# REDMINE_HUB_PROJECTのWikiから、プロダクト識別子（プレフィックス）の一覧ページ
# （REDMINE_REQ_INDEX_PAGE）を取得する。
# 使い方: get_req_index.sh <out_file>
#   out_file 取得したページ本文の保存先
# 標準出力には、update_req_index.sh へ渡す版番号を表示する（ページが未作成の場合は "new"）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY REDMINE_HUB_PROJECT REDMINE_REQ_INDEX_PAGE
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_req_index.sh <out_file>" >&2
    exit 1
fi

OUT_FILE="$1"

require_hub_project

PAGE_URL="$REDMINE_URL/projects/$REDMINE_HUB_PROJECT/wiki/$(uri_encode "$REDMINE_REQ_INDEX_PAGE").json"

RESPONSE="$(curl -sS \
    -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
    -w '\n%{http_code}' \
    "$PAGE_URL")"
HTTP_CODE="$(echo "$RESPONSE" | tail -n1)"
BODY="$(echo "$RESPONSE" | sed '$d')"

case "$HTTP_CODE" in
    200)
        # -j: 本文末尾に改行を足さない（取得→更新を繰り返しても本文が変化しないようにする）
        echo "$BODY" | jq -j '.wiki_page.text' > "$OUT_FILE"
        echo "$BODY" | jq -r '.wiki_page.version'
        ;;
    404)
        # ページが未作成の場合（Wikiモジュールが無効な場合も404になりうるため、両方を案内する）
        echo "Wikiページ '$REDMINE_REQ_INDEX_PAGE' がプロジェクト '$REDMINE_HUB_PROJECT' に見つかりません。" >&2
        echo "ページを新規作成する場合は、版番号に new を指定して update_req_index.sh を実行してください。" >&2
        echo "Wikiモジュールが無効になっていないかも確認してください。" >&2
        : > "$OUT_FILE"
        echo "new"
        ;;
    403)
        echo "Wikiページを参照する権限がありません（HTTP 403）。" >&2
        echo "プロジェクト '$REDMINE_HUB_PROJECT' でWikiモジュールが有効か、APIキーのユーザーにWikiの閲覧権限があるかを確認してください。" >&2
        exit 1
        ;;
    *)
        echo "Wikiページの取得に失敗しました（HTTP $HTTP_CODE）。" >&2
        exit 1
        ;;
esac
