#!/usr/bin/env bash
#
# 設定済みのRedmineインスタンス一覧を表示する（Redmineへの通信は行わない）。
# 使い方: list_instances.sh
#
# 名前付きインスタンス（REDMINE_URL_<NAME> / REDMINE_API_KEY_<NAME>）を「<NAME>: <URL>」で
# 列挙し、最後に「デフォルト: ...」として、REDMINE_INSTANCE未指定時に実際に使われる
# デフォルトインスタンスの解決結果を表示する。APIキーの値は一部でも出力しない。
#
# 各インスタンス名の後ろには、AIエージェントが書き込み内容へCo-Authored-By行（AIシグネチャ）を
# 付与する必要があるかどうか（REDMINE_AI_SIGNATURE_<NAME>の値。未設定時は必須）もあわせて
# 表示する。詳細はSKILL.mdの「AIエージェントによる書き込みの開示（AIシグネチャ）」を参照。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "設定ファイル（${CONFIG_FILE}）が見つかりません。" >&2
    echo "docs/setup.mdの手順に従って作成してください（テンプレート: redmine-env.example）。" >&2
    exit 1
fi

mapfile -t NAMES < <(compgen -v | grep -E '^REDMINE_URL_' | sed 's/^REDMINE_URL_//' | sort || true)

declare -A URL_OF
for name in "${NAMES[@]}"; do
    varname="REDMINE_URL_${name}"
    URL_OF["$name"]="${!varname}"
done

for name in "${NAMES[@]}"; do
    if ! is_url_format "${URL_OF[$name]}"; then
        echo "${name}: (URL形式エラー)"
        continue
    fi
    line="${name}: ${URL_OF[$name]} $(ai_signature_note "$name")"
    for other in "${NAMES[@]}"; do
        [ "$other" = "$name" ] && continue
        is_url_format "${URL_OF[$other]}" || continue
        if [ "${URL_OF[$other]}" = "${URL_OF[$name]}" ]; then
            line="${line} （${other}と同じインスタンス）"
        fi
    done
    echo "$line"
done

SUFFIXLESS_URL="${REDMINE_URL:-}"
DEFAULT_LINE=""

if [ -n "${REDMINE_DEFAULT:-}" ]; then
    if [[ "$REDMINE_DEFAULT" =~ ^[A-Za-z0-9_]+$ ]]; then
        if [ -n "${URL_OF[$REDMINE_DEFAULT]+set}" ]; then
            DEFAULT_URL="${URL_OF[$REDMINE_DEFAULT]}"
            if ! is_url_format "$DEFAULT_URL"; then
                DEFAULT_LINE="(URL形式エラー) REDMINE_DEFAULT=${REDMINE_DEFAULT} の値がURL形式ではありません"
            elif [ -n "$SUFFIXLESS_URL" ] && [ "${SUFFIXLESS_URL%/}" != "${DEFAULT_URL%/}" ]; then
                DEFAULT_LINE="(衝突) 接尾辞なし設定(${SUFFIXLESS_URL}) と REDMINE_DEFAULT=${REDMINE_DEFAULT}(${DEFAULT_URL}) が異なるインスタンスを指しています"
            else
                DEFAULT_LINE="$REDMINE_DEFAULT"
            fi
        else
            DEFAULT_LINE="(未解決) REDMINE_DEFAULT=${REDMINE_DEFAULT} が指定されていますが REDMINE_URL_${REDMINE_DEFAULT} が設定されていません"
        fi
    else
        DEFAULT_LINE="(未解決) REDMINE_DEFAULT=${REDMINE_DEFAULT} に使用できない文字が含まれています"
    fi
elif [ -n "$SUFFIXLESS_URL" ]; then
    DEFAULT_LINE="(接尾辞なし設定) ${SUFFIXLESS_URL} $(ai_signature_note "")"
else
    DEFAULT_LINE="(未設定)"
fi

echo "デフォルト: ${DEFAULT_LINE}"
