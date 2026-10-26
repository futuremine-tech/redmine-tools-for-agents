#!/usr/bin/env bash
#
# 起点チケットから、本文・コメント中に検出したRedmineチケットへのリンク（フルURL形式のみ。
# "#N" の裸参照は誤検出リスクがあるため自動追跡の対象外）を再帰的に辿り、関連チケットの
# 内容もあわせて出力する。
# 使い方: get_issue_recursive.sh <issue_id> [max_depth]
#   max_depth: 何階層先まで辿るか（デフォルト2、上限5）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_config REDMINE_URL REDMINE_API_KEY
require_jq

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "使い方: get_issue_recursive.sh <issue_id> [max_depth]" >&2
    exit 1
fi

ROOT_ISSUE_ID="$1"
MAX_DEPTH="${2:-2}"
HARD_MAX_DEPTH=5
if [ "$MAX_DEPTH" -gt "$HARD_MAX_DEPTH" ]; then
    MAX_DEPTH="$HARD_MAX_DEPTH"
fi

declare -A VISITED

visit() {
    local issue_id="$1"
    local depth="$2"
    local referenced_from="$3"

    if [ -n "${VISITED[$issue_id]:-}" ]; then
        return
    fi
    VISITED[$issue_id]=1

    if [ "$depth" -eq 0 ]; then
        echo "--- issue #$issue_id ---"
    else
        echo "--- issue #$issue_id (depth $depth, referenced from #$referenced_from) ---"
    fi
    "$SCRIPT_DIR/get_issue.sh" "$issue_id"
    echo

    if [ "$depth" -ge "$MAX_DEPTH" ]; then
        return
    fi

    local raw text next_id
    raw="$(curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/issues/$issue_id.json?include=journals")"
    text="$(echo "$raw" | jq -r '[(.issue.description // ""), (.issue.journals[]? | .notes // "")] | join("\n")')"

    while read -r next_id; do
        [ -n "$next_id" ] || continue
        visit "$next_id" "$((depth + 1))" "$issue_id"
    done < <(extract_issue_refs "$text" | grep '^URL_REF' | awk '{print $2}' | sort -u || true)
}

visit "$ROOT_ISSUE_ID" 0 ""
