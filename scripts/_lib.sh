#!/usr/bin/env bash
#
# redmine-toolsスキルの各スクリプトが共有するヘルパー関数群。
# 各スクリプトの先頭で `source "$SCRIPT_DIR/_lib.sh"` として読み込んで使用する。
# 単体では実行しない。

CONFIG_FILE="$HOME/.config/redmine-env"

# 使い方: load_config REDMINE_URL REDMINE_API_KEY ...
# 呼び出し元が必要とする環境変数名を引数で渡す。
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    # REDMINE_URLの末尾にスラッシュが含まれていても、以降の "$REDMINE_URL/xxx" という
    # 結合で二重スラッシュにならないよう正規化する。
    REDMINE_URL="${REDMINE_URL%/}"

    local missing=()
    local var
    for var in "$@"; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "${missing[*]} が設定されていません。" >&2
        echo "$CONFIG_FILE を用意してください（テンプレート: redmine-env.example）。" >&2
        exit 1
    fi
}

require_jq() {
    if ! command -v jq > /dev/null 2>&1; then
        echo "jq が見つかりません。jq をインストールしてください。" >&2
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

    if ! curl -sS -f -o /dev/null \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$(uri_encode "$project_identifier").json"; then
        echo "project_id '$project_id' に対応するRedmineプロジェクト '$project_identifier' が見つかりません。" >&2
        echo "Redmine側で先にプロジェクトを作成するか、$PROJECT_MAP_FILE でエイリアスを設定してください。" >&2
        exit 1
    fi

    echo "$project_identifier"
}

# ステータス名からstatus_idを解決する。見つからない場合は候補一覧を表示して終了する。
resolve_status_id() {
    local status_name="$1"
    local statuses_json
    statuses_json="$(curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/issue_statuses.json")"

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

# プロジェクトで有効化されているトラッカー一覧（JSON、プロジェクト本体の情報含む）を取得する。
# トラッカーはプロジェクトごとに有効化するものを選べるため、グローバルな/trackers.jsonではなく
# 本関数（プロジェクトに紐づく/projects/<id>.json?include=trackers）で取得する。
# 使い方: fetch_project_trackers_json <project_identifier>
fetch_project_trackers_json() {
    local project_identifier="$1"
    curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$project_identifier.json?include=trackers"
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
    curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$project_identifier/issue_categories.json"
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
    curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$project_identifier/versions.json"
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
    project_numeric_id="$(curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/issues/$issue_id.json" | jq -r '.issue.project.id')"

    curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$project_numeric_id.json" | jq -r '.project.identifier'
}

# チケットのステータスが、Redmineのステータス設定で「終了したチケット」として扱われているかを
# 確認する。ステータス名ではなく、Redmine側の設定（is_closed）で判定する（ステータス名を
# スキルに固定しない方針と整合させるため）。
# 使い方: is_issue_closed <issue_id>
# 終了扱いであれば "true"、そうでなければ "false" を標準出力に返す。
is_issue_closed() {
    local issue_id="$1"
    curl -sS -f \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/issues/$issue_id.json" | jq -r '.issue.status.is_closed'
}

# 文字列をURLのパス要素としてエンコードする（Wikiページ名に日本語・空白等を含む場合に備える）。
# 使い方: uri_encode <string>
uri_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# REDMINE_HUB_PROJECT（プロダクト横断の情報を管理するプロジェクト）が存在することを確認する。
# 存在しない場合、またはAPIキーのユーザーから参照できない場合はエラーを表示して終了する。
require_hub_project() {
    if ! curl -sS -f -o /dev/null \
        -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
        "$REDMINE_URL/projects/$REDMINE_HUB_PROJECT.json"; then
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
