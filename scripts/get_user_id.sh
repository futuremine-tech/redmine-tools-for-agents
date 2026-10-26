#!/usr/bin/env bash
#
# Redmineのログイン名からユーザーID（assigned_to_id等に使う数値ID）を解決する。
# 使い方: get_user_id.sh <login>
#
# このAPIの参照にはAPIキーのユーザーに管理者権限が必要（Redmineの仕様上、ユーザー一覧
# エンドポイントが管理者専用のため）。権限不足の場合は、ユーザーに対象ユーザーのRedmineユーザーID
# （数値）を確認してもらい、create_issue.sh --assignee にログイン名の代わりそのIDを直接
# 指定すること（--assigneeは数値IDも受け付ける）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: get_user_id.sh <login>" >&2
    exit 1
fi

resolve_assigned_to_id "$1"
