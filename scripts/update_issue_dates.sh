#!/usr/bin/env bash
#
# Redmineの要件チケットの開始日・期日を更新する。
# 使い方: update_issue_dates.sh <issue_id> [--start-date <YYYY-MM-DD>] [--due-date <YYYY-MM-DD>]
#   issue_id      対象チケットのID。カンマ区切りで複数指定できる（例: 101,102,103）
#   --start-date  開始日（YYYY-MM-DD）。省略可
#   --due-date    期日（YYYY-MM-DD）。省略可
#
# --start-date・--due-dateの少なくとも一方の指定が必要。期日を開始日より前にする等、Redmine側の
# 検証で不正な場合はエラーメッセージ（Redmine側の検証エラー内容を含む）を表示して終了する。
# 複数ID指定時は1件ずつ更新し、一部が失敗しても他のIDの更新は続行したうえで、失敗したIDを
# 最後にまとめて報告する（終了コード1）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

usage() {
    echo "使い方: update_issue_dates.sh <issue_id> [--start-date <YYYY-MM-DD>] [--due-date <YYYY-MM-DD>]" >&2
    exit 1
}

START_DATE=""
DUE_DATE=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --start-date)
            [ "$#" -ge 2 ] || usage
            START_DATE="$2"
            shift 2
            ;;
        --due-date)
            [ "$#" -ge 2 ] || usage
            DUE_DATE="$2"
            shift 2
            ;;
        --*)
            echo "不明なオプション: $1" >&2
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

[ "${#POSITIONAL[@]}" -eq 1 ] || usage
ISSUE_IDS_RAW="${POSITIONAL[0]}"

if [ -z "$START_DATE" ] && [ -z "$DUE_DATE" ]; then
    echo "--start-date または --due-date のいずれかを指定してください。" >&2
    exit 1
fi

if [ -n "$START_DATE" ] && ! [[ "$START_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "開始日はYYYY-MM-DD形式で指定してください: $START_DATE" >&2
    exit 1
fi

if [ -n "$DUE_DATE" ] && ! [[ "$DUE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "期日はYYYY-MM-DD形式で指定してください: $DUE_DATE" >&2
    exit 1
fi

PAYLOAD="$(jq -n '{issue: {}}')"

if [ -n "$START_DATE" ]; then
    PAYLOAD="$(echo "$PAYLOAD" | jq --arg start_date "$START_DATE" '.issue.start_date = $start_date')"
fi

if [ -n "$DUE_DATE" ]; then
    PAYLOAD="$(echo "$PAYLOAD" | jq --arg due_date "$DUE_DATE" '.issue.due_date = $due_date')"
fi

update_one_issue_dates() {
    local ISSUE_ID="$1"
    api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null
    echo "チケット #$ISSUE_ID の日付を更新しました（開始日: ${START_DATE:-変更なし}, 期日: ${DUE_DATE:-変更なし}）。"
}

run_for_each_issue_id "$ISSUE_IDS_RAW" update_one_issue_dates
