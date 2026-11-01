#!/usr/bin/env bash
#
# 本リポジトリのスキル本体（SKILL.md・scripts/・requirements.txt・*.example*）を、
# AIエージェントが読み込むディレクトリ（既定: .claude/skills/redmine-tools-for-agents/）へ配置する。
# README.md・docs/・develop/・.git等、スキル本体ではないファイルはコピーしない。
#
# 使い方:
#   install.sh --user            [--target claude|copilot]
#   install.sh --project <path>  [--target claude|copilot]
#
#   --user            ~/.claude/skills/redmine-tools-for-agents へ配置する（ユーザー全体で使う）
#   --project <path>  <path>/.claude/skills/redmine-tools-for-agents へ配置する（そのプロジェクトのみ）
#   --target          配置先ディレクトリ名を切り替える（省略時はclaude）。GitHub Copilotでは
#                      .claude/skillsに配置しても認識されず、.copilot/skillsへの配置が必要だった
#                      という報告があるため、copilotを指定すると.copilot/skillsへ配置する
#
# 本リポジトリを更新した場合は、配置先を更新するために本スクリプトを再実行する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="redmine-tools-for-agents"

usage() {
    echo "使い方: install.sh --user | --project <path> [--target claude|copilot]" >&2
    exit 1
}

[ "$#" -ge 1 ] || usage

TARGET_DIR_NAME=".claude"

case "$1" in
    --user)
        BASE_DIR="$HOME"
        shift
        ;;
    --project)
        [ "$#" -ge 2 ] || usage
        [ -d "$2" ] || { echo "プロジェクトディレクトリが見つかりません: $2" >&2; exit 1; }
        BASE_DIR="$2"
        shift 2
        ;;
    *)
        usage
        ;;
esac

if [ "$#" -gt 0 ]; then
    [ "$1" = "--target" ] && [ "$#" -ge 2 ] || usage
    case "$2" in
        claude)
            TARGET_DIR_NAME=".claude"
            ;;
        copilot)
            TARGET_DIR_NAME=".copilot"
            ;;
        *)
            echo "--targetにはclaudeまたはcopilotを指定してください: $2" >&2
            exit 1
            ;;
    esac
    shift 2
fi

[ "$#" -eq 0 ] || usage

DEST_ROOT="$BASE_DIR/$TARGET_DIR_NAME/skills"

DEST_SKILL_DIR="$DEST_ROOT/$SKILL_NAME"
mkdir -p "$DEST_ROOT"

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp "$SCRIPT_DIR/SKILL.md" "$STAGE_DIR/"
cp "$SCRIPT_DIR/requirements.txt" "$STAGE_DIR/"
cp "$SCRIPT_DIR/redmine-env.example" "$STAGE_DIR/"
cp "$SCRIPT_DIR/redmine-project-map.example.json" "$STAGE_DIR/"
cp -r "$SCRIPT_DIR/scripts" "$STAGE_DIR/"

if [ -d "$DEST_SKILL_DIR" ]; then
    if diff -rq "$STAGE_DIR" "$DEST_SKILL_DIR" > /dev/null 2>&1; then
        echo "スキルは最新状態です: $DEST_SKILL_DIR"
        exit 0
    fi

    echo "配置先との間に差分があります:"
    echo "  配置元: 本リポジトリ"
    echo "  配置先: $DEST_SKILL_DIR"
    echo ""
    diff -ru "$DEST_SKILL_DIR" "$STAGE_DIR" || true
    echo ""
    # 非対話実行（標準入力がEOFの場合）はreadコマンド自体が失敗する。set -eが有効なため、
    # ここでフォールバックしないと、デフォルト値（N）に達する前にスクリプトが無言で終了してしまう。
    read -r -p "上書きしますか？ (y/N): " ANSWER || ANSWER="N"
    ANSWER="${ANSWER:-N}"
    case "$ANSWER" in
        [yY]|[yY][eE][sS])
            # ディレクトリ自体をrm -rfしてから再作成する方式だと、配置先をClaude Code自身が
            # 使用中の場合に「Device or resource busy」になることがある。ファイル単位の
            # 上書きコピー＋不要ファイルの削除に留め、ディレクトリそのものは削除しない。
            cp -r "$STAGE_DIR/." "$DEST_SKILL_DIR/"
            SRC_FILES="$(cd "$STAGE_DIR" && find . -type f | sort)"
            DEST_FILES="$(cd "$DEST_SKILL_DIR" && find . -type f | sort)"
            STALE_FILES="$(comm -13 <(echo "$SRC_FILES") <(echo "$DEST_FILES") || true)"
            if [ -n "$STALE_FILES" ]; then
                while IFS= read -r REL; do
                    [ -n "$REL" ] || continue
                    rm -f "${DEST_SKILL_DIR:?}/${REL:?}"
                done <<< "$STALE_FILES"
            fi
            echo "配置しました: $DEST_SKILL_DIR"
            ;;
        *)
            echo "配置を中止しました。"
            ;;
    esac
else
    cp -r "$STAGE_DIR" "$DEST_SKILL_DIR"
    echo "新規に配置しました: $DEST_SKILL_DIR"
fi
