# redmine-tools-for-agents

Redmineのチケット・プロジェクト操作を行うAIエージェント向けスキル。

- **対応AIエージェント**: Claude Codeで動作確認済み。GitHub Copilotでも動作するが、配置先ディレクトリ
  がClaude Codeとは異なる（詳細は[`docs/setup.md`](docs/setup.md)のセットアップ手順1を参照）
- **対応環境**: 動作確認はWindows（Git Bash）で行っている。各スクリプトは標準的なbash・
  POSIXコマンド（`curl`・`jq`・`find`・`comm`等）のみに依存しているため、Linux・macOSでも
  動作すると考えられるが、実機での確認はできていない

## できること

- 複数のRedmineインスタンスを扱う（接続先の切り替え）
- プロジェクト一覧の参照
- チケットの作成・参照（単体・複数ID一括・親子ツリー一括・プロジェクト単位一覧）・開始日・期日の編集
- トラッカー・カテゴリ・対象バージョンの参照・設定
- 関連チケットの設定、コピー系譜・スケジュール依存チェーンの一括追跡
- チケットのステータス更新・コメント追記・本文編集
- 同じ担当者のタスクの期間重複（負荷集中）の検出
- プロダクト識別子（プレフィックス）一覧の一元管理（複数プロダクト間での重複防止）

## セットアップ

使い始める前に、人間が以下を用意する必要がある。

1. `curl`・`jq`のインストール
2. `install.sh`でClaude Code（またはGitHub Copilot）へ本スキルを配置
3. `~/.config/redmine-env`の作成（接続先RedmineのURL・APIキー等）
4. Redmine側の準備（プロジェクト・トラッカー・ステータス・ワークフロー等）

詳しい手順は[`docs/setup.md`](docs/setup.md)を参照。

## 使い方

セットアップが済んでいれば、人間が各スクリプトを直接呼び出す必要は無い。Claude Code等のAI
エージェントが本スキルを自動的に認識し、Redmineのチケット・プロジェクトに関する操作が必要な
場面で自律的にスクリプトを呼び出す。人間はAIエージェントに自然言語で指示するだけでよい
（例:「このバグをRedmineにチケット登録して」「チケット#123を完了にして」）。

スキルとしての使い方・各スクリプトの詳細は[`SKILL.md`](SKILL.md)を参照。開発フロー（要件定義→設計→
実装等のSTEP区切り）と組み合わせた活用例は[`docs/example-step-workflow.md`](docs/example-step-workflow.md)
を参照。複数のRedmineインスタンスを設定している場合の呼び出しの流れは
[`docs/multi-instance-sequences.md`](docs/multi-instance-sequences.md)を参照。

## ライセンス

Copyright (c) 2026 [Futuremine Technologies](https://futuremine.jp/). [MIT License](LICENSE)
