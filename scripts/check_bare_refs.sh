#!/usr/bin/env bash
#
# Redmineへ投稿するファイル（description_file・note_file）に、裸の#N・##N参照が
# 日本語の文字に直接隣接していないかを単体でチェックする。
# create_issue.sh・add_issue_note.sh・update_issue_status.shは投稿前に
# このチェックを自動実行するため、通常は本スクリプトを個別に呼ぶ必要はない。
#
# 使い方: check_bare_refs.sh <file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

require_jq

if [ "$#" -ne 1 ]; then
    echo "使い方: check_bare_refs.sh <file>" >&2
    exit 1
fi

if [ ! -f "$1" ]; then
    echo "ファイルが見つかりません: $1" >&2
    exit 1
fi

check_bare_refs "$1"
