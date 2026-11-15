#!/usr/bin/env bash
#
# Redmineの要件チケットのステータスを更新する。
# 使い方: update_issue_status.sh <issue_id> <abstract_status> [note_file]
#   issue_id        対象チケットのID。カンマ区切りで複数指定できる（例: 101,102,103）
#   abstract_status 抽象ステータス（new, working, done, reject のいずれか）。対象チケットが属する
#                   プロジェクトの ~/.config/redmine-role-map.json の`status`から、実際の
#                   ステータス名を解決する
#   note_file       ステータス変更と同時に追記するコメントを書いたテキストファイル（省略可。
#                   複数ID指定時は同じ内容のコメントを各チケットに追記する）
#
# 複数ID指定時は1件ずつ更新し、一部が失敗しても他のIDの更新は続行したうえで、失敗したIDを
# 最後にまとめて報告する（終了コード1）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "使い方: update_issue_status.sh <issue_id> <abstract_status> [note_file]" >&2
    exit 1
fi

ISSUE_IDS_RAW="$1"
ABSTRACT_STATUS="$2"
NOTE_FILE="${3:-}"

if [ -n "$NOTE_FILE" ]; then
    if [ ! -f "$NOTE_FILE" ]; then
        echo "コメントファイルが見つかりません: $NOTE_FILE" >&2
        exit 1
    fi
    check_bare_refs "$NOTE_FILE"
fi

update_one_issue_status() {
    local ISSUE_ID="$1"

    # IDごとにプロジェクトが異なりうるため、役割マッピングの解決（抽象ステータスから実際の
    # ステータス名への変換）もID単位で行う。
    local PROJECT_IDENTIFIER STATUS_NAME STATUS_ID PAYLOAD ACTUAL_STATUS_NAME
    PROJECT_IDENTIFIER="$(fetch_issue_project_identifier "$ISSUE_ID")"
    STATUS_NAME="$(resolve_role_name "$PROJECT_IDENTIFIER" status "$ABSTRACT_STATUS")"
    STATUS_ID="$(resolve_status_id "$STATUS_NAME")"

    if [ -n "$NOTE_FILE" ]; then
        PAYLOAD="$(jq -n \
            --argjson status_id "$STATUS_ID" \
            --rawfile notes "$NOTE_FILE" \
            '{issue: {status_id: $status_id, notes: $notes}}')"
    else
        PAYLOAD="$(jq -n \
            --argjson status_id "$STATUS_ID" \
            '{issue: {status_id: $status_id}}')"
    fi

    api_mutate PUT "$REDMINE_URL/issues/$ISSUE_ID.json" "$PAYLOAD" > /dev/null

    ACTUAL_STATUS_NAME="$(verify_status_update "$ISSUE_ID" "$STATUS_ID")"

    echo "チケット #$ISSUE_ID のステータスを「$ACTUAL_STATUS_NAME」（抽象ステータス: $ABSTRACT_STATUS）に更新しました。"
}

run_for_each_issue_id "$ISSUE_IDS_RAW" update_one_issue_status
