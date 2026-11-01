#!/usr/bin/env bash
#
# Redmineに要件チケット（issue）を作成する。
# 使い方: create_issue.sh [--parent <parent_issue_id>] [--category <category_name>]
#                          [--tracker <tracker_name> | --tracker-role <role>] [--assignee <login>]
#                          [--due-date <YYYY-MM-DD>] [--version <version_name>]
#                          <project_id> <subject> <description_file>
#   project_id         Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でもよい。
#                      ~/.config/redmine-project-map.json にエイリアスを設定している場合はそちらが
#                      優先される
#   subject           チケットの件名
#   description_file  チケット本文を書いたテキストファイルのパス
#   --parent          親チケットのID（要件分割時に子チケットへ指定する。省略可）
#   --category        カテゴリ名（対象プロジェクトに存在するもの。完全一致。省略可）。存在しない
#                      場合は自動作成せずエラー終了する（作成は create_category.sh で行う）
#   --tracker         トラッカー名を直接指定する（省略可。対象プロジェクトで有効なものに限る）。
#                      --tracker-role と同時に指定することはできない
#   --tracker-role     トラッカーの役割名（省略可。省略時・両方省略時は`default`）。
#                      ~/.config/redmine-role-map.json の該当プロジェクトの`tracker`から実際の
#                      トラッカー名を解決する。ユーザー対応タスクを登録する場合は`user_task`を指定
#                      する
#   --assignee        担当者のRedmineログイン名、または数値のユーザーID（省略可）。ログイン名を
#                      渡した場合は/users.jsonで解決するため、APIキーのユーザーに管理者権限が必要。
#                      管理者権限が無い場合は、数値のユーザーIDを直接指定する（get_user_id.sh参照）
#   --due-date        期日（YYYY-MM-DD、省略可）
#   --version         対象バージョン名（対象プロジェクトに存在するもの。完全一致。省略可）。存在
#                      しない場合は自動作成せずエラー終了する（作成はユーザーがRedmine管理画面で行う）
#
# 作成されるチケットのステータスは指定しない（Redmine側のトラッカーに設定された既定の初期ステータス
# になる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

usage() {
    echo "使い方: create_issue.sh [--parent <parent_issue_id>] [--category <category_name>] [--tracker <tracker_name> | --tracker-role <role>] [--assignee <login>] [--due-date <YYYY-MM-DD>] [--version <version_name>] <project_id> <subject> <description_file>" >&2
    exit 1
}

PARENT_ISSUE_ID=""
CATEGORY_NAME=""
TRACKER_NAME=""
TRACKER_ROLE=""
ASSIGNEE_LOGIN=""
DUE_DATE=""
VERSION_NAME=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --parent)
            [ "$#" -ge 2 ] || usage
            PARENT_ISSUE_ID="$2"
            shift 2
            ;;
        --category)
            [ "$#" -ge 2 ] || usage
            CATEGORY_NAME="$2"
            shift 2
            ;;
        --tracker)
            [ "$#" -ge 2 ] || usage
            TRACKER_NAME="$2"
            shift 2
            ;;
        --tracker-role)
            [ "$#" -ge 2 ] || usage
            TRACKER_ROLE="$2"
            shift 2
            ;;
        --assignee)
            [ "$#" -ge 2 ] || usage
            ASSIGNEE_LOGIN="$2"
            shift 2
            ;;
        --due-date)
            [ "$#" -ge 2 ] || usage
            DUE_DATE="$2"
            shift 2
            ;;
        --version)
            [ "$#" -ge 2 ] || usage
            VERSION_NAME="$2"
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

[ "${#POSITIONAL[@]}" -eq 3 ] || usage

PROJECT_ID_INPUT="${POSITIONAL[0]}"
SUBJECT="${POSITIONAL[1]}"
DESCRIPTION_FILE="${POSITIONAL[2]}"

if [ -n "$PARENT_ISSUE_ID" ] && ! [[ "$PARENT_ISSUE_ID" =~ ^[0-9]+$ ]]; then
    echo "親チケットIDは数値で指定してください: $PARENT_ISSUE_ID" >&2
    exit 1
fi

if [ -n "$DUE_DATE" ] && ! [[ "$DUE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "期日はYYYY-MM-DD形式で指定してください: $DUE_DATE" >&2
    exit 1
fi

if [ ! -f "$DESCRIPTION_FILE" ]; then
    echo "説明ファイルが見つかりません: $DESCRIPTION_FILE" >&2
    exit 1
fi

check_bare_refs "$DESCRIPTION_FILE"

if [ -n "$TRACKER_NAME" ] && [ -n "$TRACKER_ROLE" ]; then
    echo "--tracker と --tracker-role は同時に指定できません。" >&2
    exit 1
fi

PROJECT_ID="$(resolve_project_identifier "$PROJECT_ID_INPUT")"

if [ -z "$TRACKER_NAME" ]; then
    TRACKER_NAME="$(resolve_role_name "$PROJECT_ID" tracker "${TRACKER_ROLE:-default}")"
fi
TRACKER_ID="$(resolve_tracker_id "$PROJECT_ID" "$TRACKER_NAME")"

PAYLOAD="$(jq -n \
    --arg project_id "$PROJECT_ID" \
    --argjson tracker_id "$TRACKER_ID" \
    --arg subject "$SUBJECT" \
    --rawfile description "$DESCRIPTION_FILE" \
    '{issue: {project_id: $project_id, tracker_id: $tracker_id, subject: $subject, description: $description}}')"

if [ -n "$PARENT_ISSUE_ID" ]; then
    PAYLOAD="$(echo "$PAYLOAD" | jq --argjson parent_issue_id "$PARENT_ISSUE_ID" '.issue.parent_issue_id = $parent_issue_id')"
fi

if [ -n "$CATEGORY_NAME" ]; then
    CATEGORY_ID="$(resolve_category_id "$PROJECT_ID" "$CATEGORY_NAME")"
    PAYLOAD="$(echo "$PAYLOAD" | jq --argjson category_id "$CATEGORY_ID" '.issue.category_id = $category_id')"
fi

if [ -n "$ASSIGNEE_LOGIN" ]; then
    if [[ "$ASSIGNEE_LOGIN" =~ ^[0-9]+$ ]]; then
        ASSIGNEE_ID="$ASSIGNEE_LOGIN"
    else
        ASSIGNEE_ID="$(resolve_assigned_to_id "$ASSIGNEE_LOGIN")"
    fi
    PAYLOAD="$(echo "$PAYLOAD" | jq --argjson assigned_to_id "$ASSIGNEE_ID" '.issue.assigned_to_id = $assigned_to_id')"
fi

if [ -n "$DUE_DATE" ]; then
    PAYLOAD="$(echo "$PAYLOAD" | jq --arg due_date "$DUE_DATE" '.issue.due_date = $due_date')"
fi

if [ -n "$VERSION_NAME" ]; then
    VERSION_ID="$(resolve_version_id "$PROJECT_ID" "$VERSION_NAME")"
    PAYLOAD="$(echo "$PAYLOAD" | jq --argjson fixed_version_id "$VERSION_ID" '.issue.fixed_version_id = $fixed_version_id')"
fi

RESPONSE="$(api_mutate POST "$REDMINE_URL/issues.json" "$PAYLOAD")"

ISSUE_ID="$(echo "$RESPONSE" | jq -r '.issue.id')"

echo "チケットを作成しました: #$ISSUE_ID"
echo "$REDMINE_URL/issues/$ISSUE_ID"
