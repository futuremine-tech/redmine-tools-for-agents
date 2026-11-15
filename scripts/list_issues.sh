#!/usr/bin/env bash
#
# Redmineプロジェクトに属するチケットを一括で一覧表示する。
# 使い方: list_issues.sh <project_id> [--include-children] [--include-closed]
#   project_id          Redmineプロジェクトの識別子（例: rts）。小文字化して使われるため大文字でも
#                        よい。~/.config/redmine-project-map.json にエイリアスを設定している場合は
#                        そちらが優先される
#   --include-children  既定では親チケットが無いチケットのみを対象にする。指定すると深さ問わず
#                        全チケットを対象にする（子チケットの詳細はget_issue_tree.shで個別に確認する
#                        運用を想定し、既定では親チケットのみに絞っている）
#   --include-closed    既定ではオープンのチケットのみを対象にする。指定すると全ステータスを対象にする
#
# project_idで指定したプロジェクトを親プロジェクトとして渡すと、Redmineの既定動作により
# サブプロジェクトのチケットも透過的に対象へ含まれる（専用のオプションは設けていない）。
# 出力はTSV形式（1行1チケット、ID・プロジェクト識別子・トラッカー・ステータス・件名・
# カテゴリ・対象バージョン・担当者・親チケットID・開始日・期日・子孫件数）。プロジェクト識別子の
# 列は、サブプロジェクトのチケットが混在していても実際の所属プロジェクトを見分けられるように
# するためのもの。子孫件数は、今回取得した範囲（既定ではオープンのみ、--include-closed指定時は
# 全件）の中だけで再帰的に算出する追加情報であり、終了済みの子孫は--include-closedを指定しない
# 限り数えない（get_issue_tree.shの--count-onlyとは範囲が異なりうる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

usage() {
    echo "使い方: list_issues.sh <project_id> [--include-children] [--include-closed]" >&2
    exit 1
}

INCLUDE_CHILDREN=""
INCLUDE_CLOSED=""
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --include-children)
            INCLUDE_CHILDREN=true
            shift
            ;;
        --include-closed)
            INCLUDE_CLOSED=true
            shift
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
PROJECT_ID="$(resolve_project_identifier "${POSITIONAL[0]}")"

STATUS_FILTER="open"
if [ -n "$INCLUDE_CLOSED" ]; then
    STATUS_FILTER="*"
fi

TOP_LEVEL_ONLY=true
if [ -n "$INCLUDE_CHILDREN" ]; then
    TOP_LEVEL_ONLY=false
fi

ISSUES_JSON="$(fetch_project_issues_json "$PROJECT_ID" "$STATUS_FILTER")"
ROWS="$(format_issue_list_rows "$ISSUES_JSON" "$TOP_LEVEL_ONLY")"

if [ -z "$ROWS" ]; then
    echo "該当するチケットはありません。"
else
    echo "$ROWS"
fi
