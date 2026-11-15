#!/usr/bin/env bash
#
# 同じ担当者のタスクが同時期に集中していないか（期間重複）を検出する。
# 使い方: list_overlap_tasks.sh (--project <識別子1,識別子2,...> | --all-projects) [--granularity day|week]
#   --project <識別子1,識別子2,...>  対象プロジェクトをカンマ区切りで指定する。--all-projectsとは
#                                     どちらか一方を指定する
#   --all-projects                    project_idを指定せず、APIキーがアクセス可能な全プロジェクトを
#                                     対象にする（担当者がプロジェクトをまたいで重複している場合に使う）
#   --granularity day|week            省略時はweek。重複判定自体は常に日単位で正確に計算し、
#                                     weekはその結果を週（月曜始まり）単位で要約表示するだけの
#                                     位置づけ（day: 重複している日ごとに1行／week: 同じ週の
#                                     重複日をまとめて1行。その週の中で誰とも重ならないチケットは
#                                     関与IDに含めない）
#
# 対象は常にオープンチケットのみ（終了済みチケット同士の重複を調整するユースケースは想定しない
# ため、--include-closed相当のオプションは設けていない）。重複判定は常に「同じ担当者」の中だけで
# 行う（担当者が異なるチケット同士は比較しない）。
#
# 出力はTSV形式（1行1重複区間。担当者・「<granularity> <日付>」の文字列・同時重複件数・
# 関与チケットID一覧）。重複が無い日・週は行自体を出力しない。
#
# 本スクリプトの役割は重複候補を絞り込むことに限定する。実際に両立可能かどうかの判断は、
# 出力された関与チケットIDに対してget_issue.shで中身（予定工数・内容等）を確認し、AIが
# 判断すること。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_instance_config
echo "対象インスタンス: ${INSTANCE_LABEL} (${REDMINE_URL})" >&2
require_jq

usage() {
    echo "使い方: list_overlap_tasks.sh (--project <識別子1,識別子2,...> | --all-projects) [--granularity day|week]" >&2
    exit 1
}

PROJECT_IDS_RAW=""
ALL_PROJECTS=""
GRANULARITY="week"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --project)
            PROJECT_IDS_RAW="$2"
            shift 2
            ;;
        --all-projects)
            ALL_PROJECTS=true
            shift
            ;;
        --granularity)
            GRANULARITY="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [ "$GRANULARITY" != "day" ] && [ "$GRANULARITY" != "week" ]; then
    usage
fi

if [ -n "$PROJECT_IDS_RAW" ] && [ -n "$ALL_PROJECTS" ]; then
    usage
fi
if [ -z "$PROJECT_IDS_RAW" ] && [ -z "$ALL_PROJECTS" ]; then
    usage
fi

if [ -n "$ALL_PROJECTS" ]; then
    ISSUES_JSON="$(fetch_issues_json "status_id=open")"
else
    PAGES_FILE="$(mktemp)"
    while IFS= read -r project_id; do
        [ -z "$project_id" ] && continue
        RESOLVED_ID="$(resolve_project_identifier "$project_id")"
        fetch_project_issues_json "$RESOLVED_ID" "open" | jq -c '.issues' >> "$PAGES_FILE"
    done < <(split_id_list "$PROJECT_IDS_RAW")
    ISSUES_JSON="$(jq -s '{issues: map(.[])}' "$PAGES_FILE")"
    rm -f "$PAGES_FILE"
fi

ROWS="$(detect_schedule_overlaps "$ISSUES_JSON" "$GRANULARITY")"

if [ -n "$ROWS" ]; then
    echo "$ROWS"
fi
