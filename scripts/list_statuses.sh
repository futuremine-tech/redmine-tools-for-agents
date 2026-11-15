#!/usr/bin/env bash
#
# Redmineインスタンス全体のステータス一覧を表示する（引数なし）。
# 使い方: list_statuses.sh
#
# ステータスはプロジェクト・トラッカーに依存しないグローバルな定義。どのトラッカーで実際に
# 遷移可能かはワークフロー設定に依存し、本スクリプトでは分からない（REST APIから取得できない）。
# 出力は「<status_id><TAB><ステータス名>」の1行1ステータス。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

STATUSES_JSON="$(fetch_all_statuses_json)"
echo "$STATUSES_JSON" | jq -r '.issue_statuses[] | "\(.id)\t\(.name)"'
