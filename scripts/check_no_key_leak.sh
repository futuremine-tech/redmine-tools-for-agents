#!/usr/bin/env bash
#
# scripts/配下のシェルスクリプトが、APIキーの値をAIのチャット文脈に乗せうる形で出力して
# いないかを機械的にチェックする（check_bare_refsと同様の位置づけの回帰防止チェック）。
# 使い方: check_no_key_leak.sh
#
# 検出対象:
#   - echo/printfの引数に $REDMINE_API_KEY が含まれる行（スクリプトが自ら出力する経路）
#   - curlに -v / --verbose / --trace / --trace-ascii が使われている行
#     （リクエストヘッダー（APIキーを含む）がそのまま標準出力・標準エラーに出てしまうため）
#
# このチェックに通ることは「APIキーが安全に扱われている」ことの十分条件ではないが、
# 将来の変更でこれらの明らかな漏えい経路が紛れ込むことを防ぐための最低限の回帰防止線とする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FOUND=0

while IFS= read -r -d '' file; do
    if grep -nE '(echo|printf)[^|]*\$REDMINE_API_KEY' "$file" > /tmp/check_no_key_leak.$$; then
        echo "APIキーをecho/printfしている可能性がある行が見つかりました: $file" >&2
        cat /tmp/check_no_key_leak.$$ >&2
        FOUND=1
    fi
    rm -f /tmp/check_no_key_leak.$$

    if grep -nE '\bcurl\b.*(-v\b|--verbose|--trace\b|--trace-ascii)' "$file" > /tmp/check_no_key_leak.$$; then
        echo "curlに-v/--verbose/--trace系オプションが使われている行が見つかりました: $file" >&2
        cat /tmp/check_no_key_leak.$$ >&2
        FOUND=1
    fi
    rm -f /tmp/check_no_key_leak.$$
done < <(find "$SCRIPT_DIR" -maxdepth 1 -name '*.sh' -not -name "$(basename "${BASH_SOURCE[0]}")" -print0)

if [ "$FOUND" -ne 0 ]; then
    echo "APIキーが出力されうる記述が見つかりました。上記の該当箇所を修正してください。" >&2
    exit 1
fi

echo "APIキーの漏えいにつながる記述は見つかりませんでした。"
