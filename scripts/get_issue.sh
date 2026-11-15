#!/usr/bin/env bash
#
# Redmineの要件チケット（issue）を参照する。
# 使い方: get_issue.sh <issue_id>
#   issue_id  対象チケットのID。カンマ区切りで複数指定できる（例: 101,102,103）
#
# チケットの件名・ステータス・カテゴリ・担当者・期日・対象バージョン・親子チケット・本文・
# コメント履歴を表示する。複数ID指定時は1件ずつ処理し、一部が失敗しても他のIDの処理は続行
# したうえで、失敗したIDを最後にまとめて報告する（終了コード1）。
# コメント履歴の各コメントには journal id（[id=<journal_id> ...]）を表示する。誤記修正等で
# edit_issue_note.sh に渡す journal_id は、この表示から特定する。
# 添付ファイルは一時ディレクトリへダウンロードし、そのローカルパスを表示する
# （AIがReadツールで画像等を直接参照できるようにするため）。
# 本文・コメント中に含まれるURL/#N参照も抽出して一覧表示する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_issue.sh <issue_id>" >&2
    exit 1
fi

ISSUE_IDS_RAW="$1"

process_one_issue() {
local ISSUE_ID="$1"

RESPONSE="$(api_get "$REDMINE_URL/issues/$ISSUE_ID.json?include=journals,attachments,children,relations")"

echo "$RESPONSE" | jq -r '
"#\(.issue.id) \(.issue.subject)",
"ステータス: \(.issue.status.name)",
"カテゴリ: \(.issue.category.name // "(なし)")",
"担当者: \(.issue.assigned_to.name // "(なし)")",
"開始日: \(.issue.start_date // "(なし)")",
"期日: \(.issue.due_date // "(なし)")",
"対象バージョン: \(.issue.fixed_version.name // "(なし)")"
'

format_actual_date_lines "$RESPONSE"

echo "$RESPONSE" | jq -r --argjson issue_id "$ISSUE_ID" "$(relation_jq_defs)"'
"親チケット: \(if .issue.parent then "#\(.issue.parent.id) \(.issue.parent.subject // "")" else "(なし)" end)",
"子チケット: \(if (.issue.children // []) | length > 0 then ([.issue.children[] | "#\(.id) \(.subject // "")"] | join(", ")) else "(なし)" end)",
"関連チケット: \(
  if (.issue.relations // []) | length > 0 then
    ([.issue.relations[] |
      (relation_other_id($issue_id)) as $other_id |
      (relation_type_from_here($issue_id)) as $type_from_here |
      "#\($other_id) (\($type_from_here | relation_type_label))"
    ] | join(", "))
  else "(なし)" end
)",
"----",
(.issue.description // "")
'

echo "----"
echo "コメント履歴:"
echo "$RESPONSE" | jq -r '
[.issue.journals[]? | select((.notes // "") != "")] as $js
| if ($js | length) == 0 then "(なし)"
  else ($js | map("[id=\(.id) \(.created_on) \(.user.name // "不明")]\n\(.notes)") | join("\n\n"))
  end
'

echo "----"
echo "添付ファイル:"
ATTACHMENTS_JSON="$(echo "$RESPONSE" | jq -c '.issue.attachments // []')"
ATTACHMENT_COUNT="$(echo "$ATTACHMENTS_JSON" | jq 'length')"
if [ "$ATTACHMENT_COUNT" -eq 0 ]; then
    echo "(なし)"
else
    DOWNLOAD_DIR="$(mktemp -d -t redmine-tools-for-agents-XXXXXX)"
    echo "$ATTACHMENTS_JSON" | jq -c '.[]' | while read -r att; do
        FILENAME="$(echo "$att" | jq -r '.filename')"
        CONTENT_URL="$(echo "$att" | jq -r '.content_url')"
        DEST="$DOWNLOAD_DIR/$FILENAME"
        api_download "$CONTENT_URL" "$DEST"
        echo "- $FILENAME -> $DEST"
    done
fi

echo "----"
echo "検出されたリンク:"

ALL_TEXT="$(echo "$RESPONSE" | jq -r '[(.issue.description // ""), (.issue.journals[]? | .notes // "")] | join("\n")')"

REFS="$(extract_issue_refs "$ALL_TEXT")"
URL_REFS="$(echo "$REFS" | grep '^URL_REF' || true)"
BARE_REFS="$(echo "$REFS" | grep '^BARE_REF' || true)"

echo "[Redmineチケットへのリンク]"
if [ -z "$URL_REFS" ]; then
    echo "(なし)"
else
    echo "$URL_REFS" | awk '{print "- #" $2 " (" $3 ")"}' | sort -u
fi

echo "[外部URL]"
EXTERNAL_URLS="$(extract_external_urls "$ALL_TEXT")"
if [ -z "$EXTERNAL_URLS" ]; then
    echo "(なし)"
else
    echo "$EXTERNAL_URLS" | sed 's/^/- /'
fi

echo "[本文中の#N参照（未確認・自動取得なし）]"
if [ -z "$BARE_REFS" ]; then
    echo "(なし)"
else
    URL_REF_IDS="$(echo "$URL_REFS" | awk '{print $2}' | sort -u)"
    BARE_IDS="$(echo "$BARE_REFS" | awk '{print $2}' | sort -u)"
    NEW_BARE_IDS="$(comm -23 <(echo "$BARE_IDS") <(echo "$URL_REF_IDS") || true)"
    if [ -z "$NEW_BARE_IDS" ]; then
        echo "(なし)"
    else
        echo "$NEW_BARE_IDS" | sed 's/^/- #/'
    fi
fi
}

# run_for_each_issue_idは各IDの処理をサブシェルで実行するため、サブシェル内での変数への
# 書き込みは呼び出し元に戻らない。「何件目か」を判定するために書き込みで状態を持つのではなく、
# 先頭のIDをあらかじめ読み取り専用の値として渡しておき、各サブシェルから読むだけにする。
ALL_SPLIT_ISSUE_IDS="$(split_id_list "$ISSUE_IDS_RAW")"
FIRST_ISSUE_ID="${ALL_SPLIT_ISSUE_IDS%%$'\n'*}"
process_one_issue_with_separator() {
    local id="$1"
    if [ "$id" != "$FIRST_ISSUE_ID" ]; then
        echo
        echo "===================="
        echo
    fi
    process_one_issue "$id"
}

run_for_each_issue_id "$ISSUE_IDS_RAW" process_one_issue_with_separator
