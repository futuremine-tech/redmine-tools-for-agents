#!/usr/bin/env bash
#
# APIキーのユーザーがアクセス可能なRedmineプロジェクトの一覧を表示する。
# 使い方: list_projects.sh
#
# 出力は「識別子<TAB>名前<TAB>親の識別子」形式（階層表示はしない。親が無ければ3列目は空、
# 親がアクセス不可等で一覧に含まれない場合は「(不明)」）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

PROJECTS_JSON="$(fetch_all_projects_json)"
format_projects_list "$PROJECTS_JSON"
