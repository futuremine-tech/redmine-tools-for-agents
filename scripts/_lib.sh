#!/usr/bin/env bash
#
# redmine-toolsスキルの各スクリプトが共有するヘルパー関数群。
# 各スクリプトの先頭で `source "$SCRIPT_DIR/_lib.sh"` として読み込んで使用する。
# 単体では実行しない。

CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/redmine-env}"

require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "jq が見つかりません。jq をインストールしてください。" >&2
        exit 1
    fi
}

# actual_start_date・actual_due_dateは、Lychee等が入っているインスタンスにのみ存在するフィールド
# であり、対応していないインスタンスのレスポンスにはキー自体が無い。キーが存在しない場合と、
# 存在して値がnullの場合を区別し、存在する場合のみ行を出力する。
# 使い方: format_actual_date_lines <issue_json>（get_issue.sh等のAPIレスポンス全体）
format_actual_date_lines() {
    local issue_json="$1"
    echo "$issue_json" | jq -r '
        .issue as $i
        | (if ($i | has("actual_start_date")) then "実開始日: \($i.actual_start_date // "(なし)")" else empty end),
          (if ($i | has("actual_due_date")) then "実終了日: \($i.actual_due_date // "(なし)")" else empty end)
    '
}

# 関連チケット1件について、自分（issue_id）から見た相手ID・関連タイプ（向きを変換した上で）・
# その日本語ラベルを求めるjqのdef一式をテキストとして返す。get_issue.sh・format_issue_tree_row
# （get_issue_tree.sh用）など、関連チケットを自分の視点に変換して表示する複数のjqプログラムから
# 共通で読み込む（個別に持つと、片方にしか変換ロジックが無い・一部の関連タイプだけ変換対象から
# 漏れる、といった食い違いが生じるため）。Redmineの関連タイプは
# relates・duplicates/duplicated・blocks/blocked・precedes/follows・copied_to/copied_from の
# 9種類（Redmine REST APIの仕様上これで全種類）。
# 使い方: jq -r --argjson issue_id <id> "$(relation_jq_defs)"'<残りのjqプログラム>'
relation_jq_defs() {
    cat <<'JQ'
def relation_type_label:
  {"relates": "関連している", "duplicates": "重複する", "duplicated": "重複される",
   "blocks": "ブロックする", "blocked": "ブロックされる",
   "precedes": "先行する", "follows": "後続する",
   "copied_to": "コピー先", "copied_from": "コピー元"} as $labels
  | . as $type | $labels[$type] // $type;
def inverse_relation_type:
  {"relates": "relates", "duplicates": "duplicated", "duplicated": "duplicates",
   "blocks": "blocked", "blocked": "blocks",
   "precedes": "follows", "follows": "precedes",
   "copied_to": "copied_from", "copied_from": "copied_to"} as $inverses
  | . as $type | $inverses[$type] // $type;
def relation_other_id(issue_id):
  if .issue_id == issue_id then .issue_to_id else .issue_id end;
def relation_type_from_here(issue_id):
  if .issue_id == issue_id then .relation_type else (.relation_type | inverse_relation_type) end;
JQ
}

# get_issue_tree.sh用。1件分のissue（include=children,relations付きで取得したもの）を
# 「ID・件名・ステータス・開始日・期日・(実開始日・実終了日)・親ID・関連チケット」のTSV1行に
# 整形する。実開始日・実終了日の列はinclude_actualがtrueの場合のみ含める（対象インスタンスに
# actual_start_date等が存在するかどうかは呼び出し元が一度だけ判定し、以降の全行に対して
# 同じ扱いにする）。
# 使い方: format_issue_tree_row <issue_json> <include_actual: true|false>
format_issue_tree_row() {
    local issue_json="$1"
    local include_actual="$2"
    echo "$issue_json" | jq -r --argjson include_actual "$include_actual" "$(relation_jq_defs)"'
        .issue as $i
        | [
            $i.id,
            $i.subject,
            $i.status.name,
            ($i.start_date // ""),
            ($i.due_date // "")
          ]
          + (if $include_actual then [($i.actual_start_date // ""), ($i.actual_due_date // "")] else [] end)
          + [
              (if $i.parent then ($i.parent.id | tostring) else "" end),
              (
                if (($i.relations // []) | length) > 0 then
                  ([$i.relations[] |
                    (relation_other_id($i.id)) as $other_id |
                    (relation_type_from_here($i.id)) as $type_from_here |
                    "#\($other_id)(\($type_from_here | relation_type_label))"
                  ] | join(","))
                else "" end
              )
            ]
        | @tsv
    '
}

# get_issue_tree.shの--count-only/--summary用。issues/<id>.json?include=childrenは、
# 子孫チケットをネストした状態でまとめて1回のAPI呼び出しで返す（id・tracker.name・subjectのみ。
# ステータス・日付等は含まれない）。このネストしたJSONを「ID・件名・トラッカー名・親ID」の
# TSV1行1チケットに平坦化する。max_depthが空文字の場合は上限無し。
# 使い方: format_issue_tree_summary_rows <tree_json> <max_depth_or_empty>
format_issue_tree_summary_rows() {
    local tree_json="$1"
    local max_depth="$2"
    echo "$tree_json" | jq -r --arg max_depth "$max_depth" '
        (if $max_depth == "" then null else ($max_depth | tonumber) end) as $limit
        | def walk($node; $depth; $parent_id):
            [$node.id, $node.subject, ($node.tracker.name // ""), ($parent_id // "")] | @tsv,
            (if ($limit == null or $depth < $limit) then
               ($node.children // [])[] as $child | walk($child; $depth + 1; $node.id)
             else empty end);
          walk(.issue; 0; null)
    ' | tr -d '\r'
}

# カンマ区切りのID一覧を1行1件に分解して標準出力へ出力する。前後の空白は取り除き、
# 空の要素（連続するカンマ・末尾カンマ等）は無視する。単一ID（カンマを含まない）の場合は
# そのID1件のみを出力する。
# 使い方: split_id_list <カンマ区切りのID文字列>
split_id_list() {
    local raw="$1"
    local item
    echo "$raw" | tr ',' '\n' | while IFS= read -r item; do
        item="$(echo "$item" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ -n "$item" ]; then
            echo "$item"
        fi
    done
}

# カンマ区切りのID一覧を分解し、1件ずつサブシェルでコールバック関数（引数: id）を実行する。
# コールバック内のexit（api_get/api_mutate等が失敗時に呼ぶexitを含む）は、そのサブシェルのみを
# 終了させ、他のIDの処理には影響しない。1件でも失敗した場合、全件の処理後に失敗したID一覧を
# 標準エラーへまとめて出力し、終了コード1で終わる（全件成功時は何も出力せず正常終了する）。
# IDを1件も指定できなかった場合（空文字列等）はエラーを表示して終了する。
# 使い方: run_for_each_issue_id <カンマ区切りのID文字列> <コールバック関数名>
run_for_each_issue_id() {
    local raw_ids="$1"
    local callback="$2"
    local -a id_list=()
    local id

    while IFS= read -r id; do
        id_list+=("$id")
    done < <(split_id_list "$raw_ids")

    if [ "${#id_list[@]}" -eq 0 ]; then
        echo "issue_idを指定してください。" >&2
        exit 1
    fi

    local -a failed_ids=()
    local cb_status
    for id in "${id_list[@]}"; do
        # サブシェルを`!`/ifの被テスト対象に直接置くと、bashの仕様上そのサブシェル内で
        # -e（errexit）が無効化されてしまい、コールバック内のコマンド置換での失敗
        # （例: `x="$(api_getなど)"`）が検知されずに後続処理へ進んでしまう。
        # そのため、いったん外側の-eを外してサブシェルを素の文として実行し、サブシェル内では
        # 明示的に`set -e`し直すことで、サブシェル内部では-eを正しく機能させたまま、
        # サブシェルの失敗で外側のループ自体が中断されないようにする。
        set +e
        ( set -e; "$callback" "$id" )
        cb_status=$?
        set -e
        if [ "$cb_status" -ne 0 ]; then
            failed_ids+=("$id")
        fi
    done

    if [ "${#failed_ids[@]}" -gt 0 ]; then
        echo "----" >&2
        echo "失敗したチケット: ${failed_ids[*]}" >&2
        exit 1
    fi
}

# 使い方: validate_instance_name <name>
# インスタンス名（REDMINE_INSTANCE・REDMINE_DEFAULTの値）が、間接参照の変数名として
# 使える文字（英数字・アンダースコアのみ）だけで構成されているかを検証する。
validate_instance_name() {
    local name="$1"
    if ! [[ "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
        echo "インスタンス名に使用できない文字が含まれています（英数字・アンダースコアのみ使用可）: $name" >&2
        exit 1
    fi
}

# 使い方: is_url_format <value>
# 値がhttp://またはhttps://で始まっているかを判定する。
is_url_format() {
    [[ "$1" =~ ^https?:// ]]
}

# 使い方: ai_signature_required <name_or_empty>
# REDMINE_AI_SIGNATURE_<name>（nameが空の場合はREDMINE_AI_SIGNATURE。接尾辞なし設定用）の値を
# 見て、そのインスタンスでAIシグネチャ（Co-Authored-By行）の付与が必要かどうかを判定する。
# 明示的に"false"が設定されている場合のみ不要と判定し、未設定・その他の値の場合は必要（既定）とみなす。
ai_signature_required() {
    local name="$1"
    local varname
    if [ -n "$name" ]; then
        varname="REDMINE_AI_SIGNATURE_${name}"
    else
        varname="REDMINE_AI_SIGNATURE"
    fi
    [ "${!varname:-}" != "false" ]
}

# 使い方: ai_signature_note <name_or_empty>
# ai_signature_requiredの判定結果を表示用の文字列にする。
ai_signature_note() {
    if ai_signature_required "$1"; then
        echo "(AIシグネチャ: 必須)"
    else
        echo "(AIシグネチャ: 不要)"
    fi
}

# 使い方: resolve_named_instance <name>
# REDMINE_URL_<name> / REDMINE_API_KEY_<name> を読み、REDMINE_URL / REDMINE_API_KEY に
# セットする（間接参照）。
resolve_named_instance() {
    local name="$1"
    local url_var="REDMINE_URL_${name}"
    local key_var="REDMINE_API_KEY_${name}"
    local url="${!url_var:-}"
    local key="${!key_var:-}"

    if [ -z "$url" ] || [ -z "$key" ]; then
        echo "${url_var} または ${key_var} が設定されていません。" >&2
        echo "$CONFIG_FILE を確認してください（テンプレート: redmine-env.example）。" >&2
        exit 1
    fi

    if ! is_url_format "$url"; then
        echo "URL形式エラー: ${url_var} の値が http:// または https:// で始まっていません。" >&2
        echo "変数名の誤り（他の変数の値が紛れ込んでいないか）を $CONFIG_FILE で確認してください。" >&2
        exit 1
    fi

    REDMINE_URL="${url%/}"
    REDMINE_API_KEY="$key"
}

# 使い方: load_instance_config
# REDMINE_INSTANCE → REDMINE_DEFAULT → 接尾辞なし設定 の順でデフォルトインスタンスを
# 解決し、REDMINE_URL / REDMINE_API_KEY / INSTANCE_LABEL をセットする。
load_instance_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    local suffixless_url="${REDMINE_URL:+${REDMINE_URL%/}}"
    local suffixless_key="${REDMINE_API_KEY:-}"

    INSTANCE_LABEL=""

    if [ -n "${REDMINE_INSTANCE:-}" ]; then
        validate_instance_name "$REDMINE_INSTANCE"
        resolve_named_instance "$REDMINE_INSTANCE"
        INSTANCE_LABEL="$REDMINE_INSTANCE"
        return
    fi

    if [ -n "${REDMINE_DEFAULT:-}" ]; then
        validate_instance_name "$REDMINE_DEFAULT"
        resolve_named_instance "$REDMINE_DEFAULT"
        if [ -n "$suffixless_url" ] && [ "${suffixless_url%/}" != "${REDMINE_URL%/}" ]; then
            echo "接尾辞なし設定（REDMINE_URL）とREDMINE_DEFAULT=$REDMINE_DEFAULTが異なるインスタンスを指しています。" >&2
            echo "どちらか一方に統一してください。" >&2
            exit 1
        fi
        INSTANCE_LABEL="$REDMINE_DEFAULT"
        return
    fi

    if [ -z "$suffixless_url" ] || [ -z "$suffixless_key" ]; then
        echo "対象のRedmineインスタンスを特定できません。" >&2
        echo "REDMINE_INSTANCE=<名前> を指定して呼び出してください。設定済みインスタンスは list_instances.sh で確認できます。" >&2
        exit 1
    fi

    REDMINE_URL="$suffixless_url"
    REDMINE_API_KEY="$suffixless_key"
    INSTANCE_LABEL="(接尾辞なし設定)"
}

# 使い方: load_default_instance_config
# REDMINE_HUB_PROJECT機能（get_req_index.sh・update_req_index.sh）専用。常にデフォルト
# インスタンスに対して動作する仕様のため、REDMINE_INSTANCEは見ない（設定されていれば、
# 無視される旨を警告する）。REDMINE_DEFAULT → 接尾辞なし設定 の順で解決する。
load_default_instance_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    if [ -n "${REDMINE_INSTANCE:-}" ]; then
        echo "REDMINE_HUB_PROJECT機能は常にデフォルトインスタンスに対して動作するため、REDMINE_INSTANCE=${REDMINE_INSTANCE} は無視されます。" >&2
    fi

    local suffixless_url="${REDMINE_URL:+${REDMINE_URL%/}}"
    local suffixless_key="${REDMINE_API_KEY:-}"

    INSTANCE_LABEL=""

    if [ -n "${REDMINE_DEFAULT:-}" ]; then
        validate_instance_name "$REDMINE_DEFAULT"
        resolve_named_instance "$REDMINE_DEFAULT"
        if [ -n "$suffixless_url" ] && [ "${suffixless_url%/}" != "${REDMINE_URL%/}" ]; then
            echo "接尾辞なし設定（REDMINE_URL）とREDMINE_DEFAULT=$REDMINE_DEFAULTが異なるインスタンスを指しています。" >&2
            echo "どちらか一方に統一してください。" >&2
            exit 1
        fi
        INSTANCE_LABEL="$REDMINE_DEFAULT"
        return
    fi

    if [ -z "$suffixless_url" ] || [ -z "$suffixless_key" ]; then
        echo "デフォルトインスタンスを特定できません。" >&2
        echo "REDMINE_DEFAULT、または接尾辞なしのREDMINE_URL / REDMINE_API_KEYを設定してください。" >&2
        exit 1
    fi

    REDMINE_URL="$suffixless_url"
    REDMINE_API_KEY="$suffixless_key"
    INSTANCE_LABEL="(接尾辞なし設定)"
}

# 使い方: api_get <URL>
# JSON GETを行い、ボディを標準出力に返す。401を明示的に検出する。
api_get() {
    local url="$1"
    local response http_code body
    response="$(curl -sS -H "X-Redmine-API-Key: $REDMINE_API_KEY" -w '\n%{http_code}' "$url")"
    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [ "$http_code" = "401" ]; then
        echo "Redmineの認証に失敗しました（HTTP 401）。対象インスタンス（${INSTANCE_LABEL}）の設定またはAPIキーを確認してください。" >&2
        exit 1
    fi
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Redmine APIの呼び出しに失敗しました（HTTP $http_code）。" >&2
        exit 1
    fi
    echo "$body"
}

# 使い方: api_get_exists <URL>
# リソースの存在確認のみ行う。存在すれば0、404相当なら1を返す。401は、存在しないのではなく
# 認証自体が失敗しているため、1（偽）とは区別して明示的にエラー終了する（exit 2）。
api_get_exists() {
    local url="$1"
    local http_code
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Redmine-API-Key: $REDMINE_API_KEY" "$url")"

    if [ "$http_code" = "401" ]; then
        echo "Redmineの認証に失敗しました（HTTP 401）。対象インスタンス（${INSTANCE_LABEL}）の設定またはAPIキーを確認してください。" >&2
        exit 2
    fi
    [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]
}

# 使い方: api_download <URL> <保存先ファイルパス>
api_download() {
    local url="$1"
    local dest="$2"
    local http_code
    http_code="$(curl -sS -o "$dest" -w '%{http_code}' -H "X-Redmine-API-Key: $REDMINE_API_KEY" "$url")"

    if [ "$http_code" = "401" ]; then
        echo "Redmineの認証に失敗しました（HTTP 401）。対象インスタンス（${INSTANCE_LABEL}）の設定またはAPIキーを確認してください。" >&2
        exit 1
    fi
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Redmine APIの呼び出しに失敗しました（HTTP $http_code）。" >&2
        exit 1
    fi
}

PROJECT_MAP_FILE="$HOME/.config/redmine-project-map.json"
ROLE_MAP_FILE="$HOME/.config/redmine-role-map.json"

# 渡された project_id からRedmineのプロジェクト識別子を解決する。デフォルトでは小文字化した
# ものをそのままプロジェクト識別子として使う（例: RTS -> rts）。$PROJECT_MAP_FILE に該当する
# project_id のエントリがあれば、そちらの値を優先する（例: {"RTS": "rts"}）。対象プロジェクトが
# 存在しない場合はエラーを表示して終了する。
resolve_project_identifier() {
    local project_id="$1"
    local project_identifier
    project_identifier="$(echo "$project_id" | tr '[:upper:]' '[:lower:]')"

    if [ -f "$PROJECT_MAP_FILE" ]; then
        local mapped
        mapped="$(jq -r --arg key "$project_id" '.[$key] // empty' "$PROJECT_MAP_FILE")"
        [ -n "$mapped" ] && project_identifier="$mapped"
    fi

    if ! [[ "$project_identifier" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "プロジェクト識別子 '$project_identifier' に使用できない文字が含まれています（英数字・ハイフン・アンダースコアのみ使用可）。" >&2
        exit 1
    fi

    if ! api_get_exists "$REDMINE_URL/projects/$(uri_encode "$project_identifier").json"; then
        echo "project_id '$project_id' に対応するRedmineプロジェクト '$project_identifier' が見つかりません。" >&2
        echo "Redmine側で先にプロジェクトを作成するか、$PROJECT_MAP_FILE でエイリアスを設定してください。" >&2
        exit 1
    fi

    echo "$project_identifier"
}

# APIキーのユーザーがアクセス可能な全プロジェクトをJSON配列として返す（limit既定25件の
# ページネーションを自動で辿る）。
# 使い方: fetch_all_projects_json
fetch_all_projects_json() {
    local limit=100
    local offset=0
    local all="[]"
    local total_count

    while true; do
        local page
        page="$(api_get "$REDMINE_URL/projects.json?limit=${limit}&offset=${offset}")"
        total_count="$(echo "$page" | jq -r '.total_count')"
        all="$(jq -c -n --argjson a "$all" --argjson b "$(echo "$page" | jq -c '.projects')" '$a + $b')"
        offset=$((offset + limit))
        if [ "$offset" -ge "$total_count" ]; then
            break
        fi
    done

    echo "$all"
}

# fetch_all_projects_jsonの結果（JSON配列）を「識別子<TAB>名前<TAB>親の識別子」形式の行に
# 変換する。親が無ければ3列目は空、親が存在するが一覧に含まれない場合（アクセス権が無い等）は
# 「(不明)」とする。
# 使い方: format_projects_list <projects_json>
format_projects_list() {
    local projects_json="$1"
    echo "$projects_json" | jq -r '
        (map({(.id | tostring): .identifier}) | add // {}) as $id_to_identifier
        | .[]
        | [
            .identifier,
            .name,
            (if .parent then ($id_to_identifier[.parent.id | tostring] // "(不明)") else "" end)
          ]
        | @tsv
    '
}

# issues.jsonをページネーション処理込みで取得する（limit/offset以外のクエリパラメータは
# 呼び出し元がquery_without_paginationとして渡す）。
# ページ数が多い（対象チケット数が多い）場合、各ページのJSONを--argjsonのコマンドライン
# 引数として蓄積していくと、OSの引数長の上限（Argument list too long）に達することがある
# ため、一時ファイルへ1ページ1行で追記し、最後にjq -s（スラープモード）でまとめて結合する。
# 使い方: fetch_issues_json <query_without_pagination>
fetch_issues_json() {
    local query="$1"
    local limit=100
    local offset=0
    local total_count
    local pages_file
    pages_file="$(mktemp)"

    while true; do
        local page
        page="$(api_get "$REDMINE_URL/issues.json?${query}&sort=id&limit=${limit}&offset=${offset}")"
        total_count="$(echo "$page" | jq -r '.total_count')"
        echo "$page" | jq -c '.issues' >> "$pages_file"
        offset=$((offset + limit))
        if [ "$offset" -ge "$total_count" ]; then
            break
        fi
    done

    jq -s '{issues: map(.[])}' "$pages_file"
    rm -f "$pages_file"
}

# プロジェクトに属する全チケット（JSON）を取得する。project_idで親プロジェクトを指定すると、
# Redmineの既定動作でサブプロジェクトのチケットも透過的に含まれる（本関数では専用のオプションを
# 設けず、この既定動作に任せる）。
# status_filterには"open"（オープンのみ）または"*"（全ステータス）を渡す。ステータス名には
# 依存せず、Redmine側のstatus_idフィルタの標準値をそのまま使う。
# 使い方: fetch_project_issues_json <project_identifier> <status_filter>
fetch_project_issues_json() {
    local project_identifier="$1"
    local status_filter="$2"
    fetch_issues_json "project_id=${project_identifier}&status_id=${status_filter}"
}

# fetch_project_issues_jsonの結果を「ID・プロジェクト識別子・トラッカー・ステータス・件名・
# カテゴリ・対象バージョン・担当者・親チケットID・開始日・期日・子孫件数」のTSV形式
# （1行1チケット）に整形する。プロジェクト識別子の列は、サブプロジェクトのチケットが透過的に
# 混在することで「親プロジェクトのつもりで見ていたら実はサブプロジェクトだった」と誤解しない
# ようにするために設けている。子孫件数は、追加のAPI呼び出しを行わず、渡されたissues_json
# （fetch_project_issues_jsonが返す、現在の一覧と同じステータス範囲のチケット一式）の中だけで
# 親子関係を再帰的にたどって算出する。そのため、--include-closedを指定していない場合、
# 終了済みの子孫はこの件数に含まれない（get_issue_tree.shの--count-onlyとは範囲が異なりうる）。
# top_level_onlyがtrueの場合は、親チケットが無い（parentキーが無いかnull）チケットのみを
# 対象にする（子チケットの詳細はget_issue_tree.shに委ねる）。
# 使い方: format_issue_list_rows <issues_json> <top_level_only: true|false>
format_issue_list_rows() {
    local issues_json="$1"
    local top_level_only="$2"
    echo "$issues_json" | jq -r --argjson top_level_only "$top_level_only" '
        (.issues) as $all
        | ($all | map(select(.parent != null)) | group_by(.parent.id) |
           map({key: (.[0].parent.id | tostring), value: (map(.id))}) | from_entries) as $children_map
        | def descendant_count:
            ($children_map[. | tostring] // []) as $direct_children
            | ($direct_children | length) + ($direct_children | map(descendant_count) | add // 0);
        $all[]
        | select(if $top_level_only then (.parent == null) else true end)
        | [
            .id,
            (.project.identifier // .project.name // ""),
            .tracker.name,
            .status.name,
            .subject,
            (.category.name // ""),
            (.fixed_version.name // ""),
            (.assigned_to.name // ""),
            (if .parent then (.parent.id | tostring) else "" end),
            (.start_date // ""),
            (.due_date // ""),
            (.id | descendant_count)
          ]
        | @tsv
    ' | tr -d '\r'
}

# ステータス名からstatus_idを解決する。見つからない場合は候補一覧を表示して終了する。
# Redmineインスタンス全体のステータス一覧（JSON）を取得する。ステータスはプロジェクト・
# トラッカーに依存しないグローバルな定義（どのトラッカーで実際に遷移可能かはワークフロー設定に
# 依存し、REST APIからは取得できない）。
# 使い方: fetch_all_statuses_json
fetch_all_statuses_json() {
    api_get "$REDMINE_URL/issue_statuses.json"
}

resolve_status_id() {
    local status_name="$1"
    local statuses_json
    statuses_json="$(fetch_all_statuses_json)"

    local status_id
    status_id="$(echo "$statuses_json" | jq -r \
        --arg name "$status_name" \
        '.issue_statuses[] | select(.name == $name) | .id' | head -n1)"

    if [ -z "$status_id" ]; then
        echo "ステータス '$status_name' がRedmineに見つかりません。既存ステータス一覧:" >&2
        echo "$statuses_json" | jq -r '.issue_statuses[].name' >&2
        exit 1
    fi

    echo "$status_id"
}

# Redmineは、対象トラッカーのワークフロー設定で許可されていない遷移をリクエストした場合でも、
# ステータスを変更せずに200を返すことがある（ワークフロー遷移の可否はREST APIから取得できない
# ため、事前には判定できない）。PUT後に対象チケットを再取得し、実際に意図したステータスに
# なっているかを確認する。なっていない場合は、現在のステータス名を表示してエラー終了する。
# 使い方: verify_status_update <issue_id> <expected_status_id>
# 成功時は、確認した現在のステータス名を標準出力に返す。
verify_status_update() {
    local issue_id="$1"
    local expected_status_id="$2"
    local issue_json actual_status_id actual_status_name

    issue_json="$(api_get "$REDMINE_URL/issues/${issue_id}.json")"
    actual_status_id="$(echo "$issue_json" | jq -r '.issue.status.id')"
    actual_status_name="$(echo "$issue_json" | jq -r '.issue.status.name')"

    if [ "$actual_status_id" != "$expected_status_id" ]; then
        echo "ステータスは変更されませんでした（現在のステータス: ${actual_status_name}）。" >&2
        echo "対象トラッカーのワークフロー設定で、このステータスへの遷移が許可されていない可能性があります。Redmine管理画面でワークフロー設定を確認してください（コメントを指定していた場合、コメント自体の追記は成功しています）。" >&2
        exit 1
    fi

    echo "$actual_status_name"
}

# プロジェクトで有効化されているトラッカー一覧（JSON、プロジェクト本体の情報含む）を取得する。
# トラッカーはプロジェクトごとに有効化するものを選べるため、グローバルな/trackers.jsonではなく
# 本関数（プロジェクトに紐づく/projects/<id>.json?include=trackers）で取得する。
# 使い方: fetch_project_trackers_json <project_identifier>
fetch_project_trackers_json() {
    local project_identifier="$1"
    api_get "$REDMINE_URL/projects/$project_identifier.json?include=trackers"
}

# トラッカー名からtracker_idを解決する（対象プロジェクトで有効化されているトラッカーに限る）。
# 見つからない場合は、そのプロジェクトで有効なトラッカー一覧を表示して終了する。
# 使い方: resolve_tracker_id <project_identifier> <tracker_name>
resolve_tracker_id() {
    local project_identifier="$1"
    local tracker_name="$2"
    local project_json
    project_json="$(fetch_project_trackers_json "$project_identifier")"

    local tracker_id
    tracker_id="$(echo "$project_json" | jq -r \
        --arg name "$tracker_name" \
        '.project.trackers[]? | select(.name == $name) | .id' | head -n1)"

    if [ -z "$tracker_id" ]; then
        echo "トラッカー '$tracker_name' がプロジェクト '$project_identifier' で有効になっていません。有効なトラッカー一覧:" >&2
        echo "$project_json" | jq -r '.project.trackers[]?.name' >&2
        exit 1
    fi

    echo "$tracker_id"
}

# ステータス・トラッカーの「役割」（例: tracker軸のdefault/user_task、status軸のnew/working/done/reject）
# から、対象プロジェクトで実際に使われている名前を$ROLE_MAP_FILEから解決する。設定ファイルが無い、
# または対象プロジェクト・軸・役割の組み合わせが設定されていない場合はエラーで終了する（自動では
# 代替しない）。設定済みの名前がRedmine側の構成変更で存在しなくなった場合は、本関数自体は成功を
# 返すが、戻り値を使うresolve_tracker_id/resolve_status_idが候補一覧付きで失敗するため、呼び出し元
# （AI）はその一覧を見て役割の対応づけをユーザーに再確認し、$ROLE_MAP_FILEを更新すること。
# 使い方: resolve_role_name <project_identifier> <axis: tracker|status> <role>
resolve_role_name() {
    local project_identifier="$1"
    local axis="$2"
    local role="$3"

    if [ ! -f "$ROLE_MAP_FILE" ]; then
        echo "役割マッピング設定ファイルが見つかりません: $ROLE_MAP_FILE" >&2
        echo "テンプレート（redmine-role-map.example.json）を元に作成してください。" >&2
        exit 1
    fi

    local name
    name="$(jq -r \
        --arg p "$project_identifier" --arg axis "$axis" --arg role "$role" \
        '.[$p][$axis][$role] // empty' "$ROLE_MAP_FILE")"

    if [ -z "$name" ]; then
        echo "プロジェクト '$project_identifier' の役割 '$role'（$axis）が $ROLE_MAP_FILE に設定されていません。" >&2
        exit 1
    fi

    echo "$name"
}

# プロジェクトのチケットカテゴリ一覧（JSON）を取得する。
# 使い方: fetch_categories_json <project_identifier>
fetch_categories_json() {
    local project_identifier="$1"
    api_get "$REDMINE_URL/projects/$project_identifier/issue_categories.json"
}

# カテゴリ名からcategory_idを解決する（完全一致）。見つからない場合は既存カテゴリ一覧を表示して
# 終了する。カテゴリの自動作成は行わない（作成は create_category.sh で明示的に行う）。
# 使い方: resolve_category_id <project_identifier> <category_name>
resolve_category_id() {
    local project_identifier="$1"
    local category_name="$2"
    local categories_json
    categories_json="$(fetch_categories_json "$project_identifier")"

    local category_id
    category_id="$(echo "$categories_json" | jq -r \
        --arg name "$category_name" \
        '.issue_categories[] | select(.name == $name) | .id' | head -n1)"

    if [ -z "$category_id" ]; then
        echo "カテゴリ '$category_name' がプロジェクト '$project_identifier' に見つかりません。既存カテゴリ一覧:" >&2
        echo "$categories_json" | jq -r '.issue_categories[].name' >&2
        echo "新しいカテゴリが必要な場合は、ユーザーの承認を得てから create_category.sh で作成してください。" >&2
        exit 1
    fi

    echo "$category_id"
}

# プロジェクトの対象バージョン一覧（JSON）を取得する。
# 使い方: fetch_versions_json <project_identifier>
fetch_versions_json() {
    local project_identifier="$1"
    api_get "$REDMINE_URL/projects/$project_identifier/versions.json"
}

# バージョン名からversion_idを解決する（完全一致）。見つからない場合は既存バージョン一覧を表示
# して終了する。バージョンの作成は本スキルでは行わない（プロジェクト・トラッカー・ステータスと
# 同様、ユーザーがRedmine管理画面で作成する）。
# 使い方: resolve_version_id <project_identifier> <version_name>
resolve_version_id() {
    local project_identifier="$1"
    local version_name="$2"
    local versions_json
    versions_json="$(fetch_versions_json "$project_identifier")"

    local version_id
    version_id="$(echo "$versions_json" | jq -r \
        --arg name "$version_name" \
        '.versions[] | select(.name == $name) | .id' | head -n1)"

    if [ -z "$version_id" ]; then
        echo "対象バージョン '$version_name' がプロジェクト '$project_identifier' に見つかりません。既存バージョン一覧:" >&2
        echo "$versions_json" | jq -r '.versions[] | "\(.name) (\(.status))"' >&2
        echo "新しいバージョンが必要な場合は、ユーザーにRedmine管理画面での作成を依頼してください。" >&2
        exit 1
    fi

    echo "$version_id"
}

# Redmineへ投稿するファイルに、裸の#N・##N参照が日本語の文字（漢字・ひらがな・カタカナ・
# 全角記号等）に直接隣接していないかをチェックする。Markdownリンク
# （`[...](...)`）の中身は対象外。違反が見つかった場合は該当行を表示してエラー終了する。
# 使い方: check_bare_refs <file>
check_bare_refs() {
    local file="$1"
    local jp_class='[\p{Han}\p{Hiragana}\p{Katakana}　-〿＀-￯]'
    local md_pat='\[[^\]]*\]\([^)]*\)'
    local url_pat='https?://\S+'
    local ref_pat="(?:(?<=${jp_class})#{1,2}[0-9]+)|(?:#{1,2}[0-9]+(?=${jp_class}))"

    local violations
    violations="$(jq -Rsr \
        --arg md_pat "$md_pat" \
        --arg url_pat "$url_pat" \
        --arg pat "$ref_pat" \
        '
        split("\n")
        | to_entries[]
        | (.key + 1) as $lineno
        | .value as $orig_line
        | ($orig_line | gsub($md_pat; "") | gsub($url_pat; "")) as $stripped_line
        | [$stripped_line | scan($pat)] as $hits
        | select(($hits | length) > 0)
        | "  行\($lineno): \($hits | join(", ")) : \($orig_line)"
        ' "$file")"

    if [ -n "$violations" ]; then
        echo "裸の#N・##N参照の前後に半角スペース・改行が無い箇所が見つかりました:" >&2
        echo "$violations" >&2
        echo "前後に半角スペースまたは改行を入れて書き直してください。" >&2
        exit 1
    fi
}

# Redmineのログイン名からユーザーID（assigned_to_id）を解決する（完全一致）。
# /users.jsonの参照にはAPIキーのユーザーに管理者権限が必要（Redmineの仕様上、ユーザー一覧
# エンドポイントが管理者専用のため）。権限不足の場合は、ユーザーに数値のRedmineユーザーIDを
# 確認してもらい、ログイン名の代わりにそのIDを直接使う（呼び出し元で数値かどうかを判定し、
# 数値であれば本関数を呼ばずにそのまま使う）。
# 使い方: resolve_assigned_to_id <login>
resolve_assigned_to_id() {
    local login="$1"
    local response http_code users_json

    response="$(curl -sS \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        -w '\n%{http_code}' \
        "$REDMINE_URL/users.json?name=$(uri_encode "$login")")"

    http_code="$(echo "$response" | tail -n1)"
    users_json="$(echo "$response" | sed '$d')"

    if [ "$http_code" = "401" ]; then
        echo "Redmineの認証に失敗しました（HTTP 401）。対象インスタンス（${INSTANCE_LABEL:-}）の設定またはAPIキーを確認してください。" >&2
        exit 1
    fi

    if [ "$http_code" = "403" ]; then
        echo "ユーザー一覧の取得（/users.json）には、APIキーのユーザーに管理者権限が必要です" >&2
        echo "（HTTP 403）。管理者権限が無い場合は、ユーザーに対象ユーザーのRedmineユーザーID" >&2
        echo "（数値）を確認してもらい、ログイン名の代わりにそのIDを直接指定してください。" >&2
        exit 1
    fi

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Redmine APIの呼び出しに失敗しました（HTTP $http_code）。" >&2
        exit 1
    fi

    local user_id
    user_id="$(echo "$users_json" | jq -r \
        --arg login "$login" \
        '.users[] | select(.login == $login) | .id' | head -n1)"

    if [ -z "$user_id" ]; then
        echo "ユーザー '$login' が見つかりません。ログイン名を確認するか、対象ユーザーの" >&2
        echo "RedmineユーザーID（数値）を直接指定してください。" >&2
        exit 1
    fi

    echo "$user_id"
}

# チケットが属するプロジェクトの識別子を取得する（update_issue_status.sh等、issue_idのみを
# 受け取るスクリプトが、ステータスの役割マッピング解決のためにプロジェクトを特定する用途）。
# /issues/<id>.jsonが返すprojectにはid・nameのみでidentifierが含まれないため、
# 一度project.idを取得してから/projects/<id>.jsonで改めてidentifierを取得する。
# 使い方: fetch_issue_project_identifier <issue_id>
fetch_issue_project_identifier() {
    local issue_id="$1"
    local project_numeric_id
    project_numeric_id="$(api_get "$REDMINE_URL/issues/$issue_id.json" | jq -r '.issue.project.id')"

    api_get "$REDMINE_URL/projects/$project_numeric_id.json" | jq -r '.project.identifier'
}

# チケットのステータスが、Redmineのステータス設定で「終了したチケット」として扱われているかを
# 確認する。ステータス名ではなく、Redmine側の設定（is_closed）で判定する（ステータス名を
# スキルに固定しない方針と整合させるため）。
# 使い方: is_issue_closed <issue_id>
# 終了扱いであれば "true"、そうでなければ "false" を標準出力に返す。
is_issue_closed() {
    local issue_id="$1"
    api_get "$REDMINE_URL/issues/$issue_id.json" | jq -r '.issue.status.is_closed'
}

# 文字列をURLのパス要素としてエンコードする（Wikiページ名に日本語・空白等を含む場合に備える）。
# 使い方: uri_encode <string>
uri_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# REDMINE_HUB_PROJECT（プロダクト横断の情報を管理するプロジェクト）が存在することを確認する。
# 存在しない場合、またはAPIキーのユーザーから参照できない場合はエラーを表示して終了する。
require_hub_project() {
    if ! api_get_exists "$REDMINE_URL/projects/$REDMINE_HUB_PROJECT.json"; then
        echo "REDMINE_HUB_PROJECT に指定されたRedmineプロジェクト '$REDMINE_HUB_PROJECT' が見つかりません。" >&2
        echo "$CONFIG_FILE の設定値と、Redmine側のプロジェクト・権限を確認してください。" >&2
        exit 1
    fi
}

# POST/PUTを実行し、HTTPステータスが2xx以外であればRedmineのエラー内容を表示して終了する。
# 成功時はレスポンスボディを標準出力に返す。
# 使い方: api_mutate <METHOD> <URL> <JSON_PAYLOAD>
api_mutate() {
    local method="$1"
    local url="$2"
    local payload="$3"

    # payloadはコマンド引数ではなく標準入力から渡す。Windows（Git Bash）では日本語を含む引数が
    # curlへ渡る際に文字化けし、Redmineが不正なJSONとしてHTTP 400を返すため。
    local response http_code body
    response="$(printf '%s' "$payload" | curl -sS \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        -H "Content-Type: application/json" \
        -X "$method" \
        --data-binary @- \
        -w '\n%{http_code}' \
        "$url")"

    http_code="$(echo "$response" | tail -n1)"
    body="$(echo "$response" | sed '$d')"

    if [ "$http_code" = "401" ]; then
        echo "Redmineの認証に失敗しました（HTTP 401）。対象インスタンス（${INSTANCE_LABEL:-}）の設定またはAPIキーを確認してください。" >&2
        exit 1
    fi

    if [ "$http_code" = "409" ]; then
        echo "他の更新と競合しました（HTTP 409）。最新の内容を取得し直してから、再度更新してください。" >&2
        exit 1
    fi

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Redmine APIの呼び出しに失敗しました（HTTP $http_code）。" >&2
        if [ -n "$body" ]; then
            if ! echo "$body" | jq -r '.errors[]?' >&2 2>/dev/null; then
                echo "$body" >&2
            fi
        fi
        exit 1
    fi

    echo "$body"
}

# 本文からRedmineチケットへのリンク（フルURL）と "#N" 形式の裸参照を抽出する。
# 標準出力に "URL_REF <issue_id> <url>" または "BARE_REF <issue_id>" を1行ずつ出力する。
# 該当箇所が無い場合でも（set -e下で）呼び出し元を中断させないよう、各パイプラインの
# 失敗は `|| true` で吸収する。
extract_issue_refs() {
    local text="$1"
    { echo "$text" | grep -oE "${REDMINE_URL}/issues/[0-9]+" | while read -r url; do
        echo "URL_REF ${url##*/} $url"
    done ; } || true
    { echo "$text" | grep -oE '#[0-9]+' | while read -r ref; do
        echo "BARE_REF ${ref#\#}"
    done ; } || true
}

# 本文中の外部URL（Redmineチケットへのリンクを除く）を抽出する。
extract_external_urls() {
    local text="$1"
    { echo "$text" \
        | grep -oE 'https?://[^][()<>[:space:]"'"'"']+' \
        | grep -vE "^${REDMINE_URL}/issues/[0-9]+$" \
        | sort -u ; } || true
}

# issue_json（issues/<id>.json?include=relations等のレスポンス全体）のrelationsから、
# 指定した非対称な関連タイプのペア（type_a/type_b。例: copied_to/copied_from、
# precedes/follows）だけを抽出し、各関連の相手チケットID・相手チケットから見た関連タイプの
# TSV（1行1関連）で返す。それ以外の関連タイプ（relates・blocks等、指定したペア以外）は
# 無視する。get_issue_copy_history.sh・get_issue_schedule_chain.shが、それぞれの系譜・
# 依存チェーンをたどる際、次にたどる先を得るために使う。
# 使い方: extract_bidirectional_relations <issue_json> <current_issue_id> <type_a> <type_b>
extract_bidirectional_relations() {
    local issue_json="$1"
    local current_id="$2"
    local type_a="$3"
    local type_b="$4"
    echo "$issue_json" | jq -r --argjson id "$current_id" --arg type_a "$type_a" --arg type_b "$type_b" "$(relation_jq_defs)"'
        (.issue.relations // [])[]
        | (relation_type_from_here($id)) as $type_from_here
        | select($type_from_here == $type_a or $type_from_here == $type_b)
        | (relation_other_id($id)) as $other_id
        | [$other_id, (relation_type_from_here($other_id))]
        | @tsv
    ' | tr -d '\r'
}

# 開始日・期日から、土日を除いた稼働日数（開始日・期日を含む）を算出する。実機確認の結果、
# Redmineのprecedes/follows日付連動は土日を考慮して後続チケットの日付をずらすため
# （先行チケットの期日を延ばすと、後続チケットの開始日は単純に翌日になるが、期日は土日分を
# 除いた同じ稼働日数を保つように調整される）、稼働日数もRedmineと同じ基準（土日を除く）で
# 数える。祝日等のカスタム非稼働日（Redmineの管理画面設定）はissueのREST APIレスポンスからは
# 取得できないため、対象外とする（土日のみを除く簡易な算出）。開始日・期日のいずれかが無い
# （null/空）場合は算出しない。
# 使い方: calculate_working_days <start_date> <due_date>
calculate_working_days() {
    local start_date="$1"
    local due_date="$2"

    if [ -z "$start_date" ] || [ -z "$due_date" ]; then
        echo ""
        return 0
    fi

    jq -n --arg start "$start_date" --arg due "$due_date" '
        def is_weekend:
            (. | gmtime | strftime("%u")) as $dow
            | ($dow == "6" or $dow == "7");
        ($start | strptime("%Y-%m-%d") | mktime) as $start_epoch
        | ($due | strptime("%Y-%m-%d") | mktime) as $due_epoch
        | (($due_epoch - $start_epoch) / 86400 | floor) as $span_days
        | ([range(0; $span_days + 1)]
           | map($start_epoch + (. * 86400))
           | map(select(is_weekend | not))
           | length)
    '
}

# issues_json（fetch_issues_json等が返す、担当者・開始日・期日を含むチケット一式）から、
# 同じ担当者の中だけで（担当者が異なるチケット同士は比較しない）、期間が重なっているチケットを
# 検出する。担当者未設定、または開始日・期日のいずれかが無いチケットは対象外にする。
# 重複判定自体は常に日単位で正確に計算する。granularity="day"の場合はそのまま日ごとに1行、
# granularity="week"の場合は週（月曜始まり）単位で要約する（その週の中で重複していた日の
# 最大同時件数・関与した全チケットIDの和集合）。週をまたいで関与していない（その週の中では
# 誰とも重ならない）チケットは、同じ週に稼働していても関与チケットID一覧に含めない。
# 出力はTSV形式（1行1重複区間。担当者・「<granularity> <日付>」の文字列・同時重複件数・
# 関与チケットID一覧（カンマ区切り））。重複が無い日・週は行自体を出力しない。
# 使い方: detect_schedule_overlaps <issues_json> <granularity: day|week>
detect_schedule_overlaps() {
    local issues_json="$1"
    local granularity="$2"
    echo "$issues_json" | jq -r --arg granularity "$granularity" '
        def to_epoch: strptime("%Y-%m-%d") | mktime;
        def week_start_epoch:
            (. | gmtime | strftime("%u") | tonumber) as $dow
            | . - (($dow - 1) * 86400);

        (.issues // [] | map(select(.assigned_to != null and .start_date != null and .due_date != null))) as $valid
        | ($valid | group_by(.assigned_to.name)) as $groups
        | [ $groups[] |
            (.[0].assigned_to.name) as $assignee
            | map({id: .id, start: (.start_date | to_epoch), due: (.due_date | to_epoch)}) as $tickets
            | (reduce $tickets[] as $t ({};
                reduce range($t.start; $t.due + 86400; 86400) as $day (.;
                    .[$day | tostring] += [$t.id]
                )
              )) as $day_map
            | ($day_map | to_entries | map(select((.value | length) >= 2)) | map(.key |= tonumber)) as $overlap_days
            | if $granularity == "day" then
                $overlap_days[] | {assignee: $assignee, bucket_epoch: .key, count: (.value | length), ids: .value}
              else
                ($overlap_days | group_by(.key | week_start_epoch))[] | {
                    assignee: $assignee,
                    bucket_epoch: (.[0].key | week_start_epoch),
                    count: (map(.value | length) | max),
                    ids: (map(.value) | add | unique)
                }
              end
          ]
        | flatten
        | sort_by(.assignee, .bucket_epoch)
        | .[]
        | [.assignee, ($granularity + " " + (.bucket_epoch | gmtime | strftime("%Y-%m-%d"))), .count, (.ids | join(","))]
        | @tsv
    ' | tr -d '\r'
}
