#!/usr/bin/env bash
#
# Redmineの要件チケット（issue）を参照する。
# 使い方: get_issue.sh <issue_id>
#
# チケットの件名・ステータス・カテゴリ・担当者・期日・対象バージョン・親子チケット・本文・
# コメント履歴を表示する。
# コメント履歴の各コメントには journal id（[id=<journal_id> ...]）を表示する。誤記修正等で
# edit_issue_note.sh に渡す journal_id は、この表示から特定する。
# 添付ファイルは一時ディレクトリへダウンロードし、そのローカルパスを表示する
# （AIがReadツールで画像等を直接参照できるようにするため）。
# 本文・コメント中に含まれるURL/#N参照も抽出して一覧表示する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_issue.sh <issue_id>" >&2
    exit 1
fi

ISSUE_ID="$1"

RESPONSE="$(curl -sS -f \
    -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
    "$REDMINE_URL/issues/$ISSUE_ID.json?include=journals,attachments,children,relations")"

echo "$RESPONSE" | jq -r --argjson issue_id "$ISSUE_ID" '
def relation_label:
  {"relates": "関連している", "duplicates": "重複する", "duplicated": "重複される",
   "blocks": "ブロックする", "blocked": "ブロックされる",
   "precedes": "先行する", "follows": "後続する"} as $labels
  | . as $type | $labels[$type] // $type;
def inverse_type:
  {"relates": "relates", "duplicates": "duplicated", "duplicated": "duplicates",
   "blocks": "blocked", "blocked": "blocks",
   "precedes": "follows", "follows": "precedes"} as $inverses
  | . as $type | $inverses[$type] // $type;
"#\(.issue.id) \(.issue.subject)",
"ステータス: \(.issue.status.name)",
"カテゴリ: \(.issue.category.name // "(なし)")",
"担当者: \(.issue.assigned_to.name // "(なし)")",
"期日: \(.issue.due_date // "(なし)")",
"対象バージョン: \(.issue.fixed_version.name // "(なし)")",
"親チケット: \(if .issue.parent then "#\(.issue.parent.id) \(.issue.parent.subject // "")" else "(なし)" end)",
"子チケット: \(if (.issue.children // []) | length > 0 then ([.issue.children[] | "#\(.id) \(.subject // "")"] | join(", ")) else "(なし)" end)",
"関連チケット: \(
  if (.issue.relations // []) | length > 0 then
    ([.issue.relations[] |
      (if .issue_id == $issue_id then .issue_to_id else .issue_id end) as $other_id |
      (if .issue_id == $issue_id then .relation_type else (.relation_type | inverse_type) end) as $type_from_here |
      "#\($other_id) (\($type_from_here | relation_label))"
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
        curl -sS -f -H "X-Redmine-API-Key: $REDMINE_API_KEY" -o "$DEST" "$CONTENT_URL"
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
