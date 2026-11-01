# redmine-tools-for-agents

Redmineのチケット・プロジェクト操作を行うAIエージェント向けスキル。チケットの作成・参照・
ステータス更新・コメント追記、プロジェクトへのアクセス確認・疎通確認、トラッカー・カテゴリ・
対象バージョン等のプロジェクト構成の参照・追加、複数プロダクトで共通のプロダクト識別子
（プレフィックス）一覧の参照・更新を行う。

- **対応AIエージェント**: Claude Codeで動作確認済み。GitHub Copilotでも動作するが、配置先ディレクトリ
  がClaude Codeとは異なる（詳細は「Claude Codeへの配置」節を参照）
- **対応環境**: 動作確認はWindows（Git Bash）で行っている。各スクリプトは標準的なbash・
  POSIXコマンド（`curl`・`jq`・`find`・`comm`等）のみに依存しているため、Linux・macOSでも
  動作すると考えられるが、実機での確認はできていない

スキルとしての使い方・AIの振る舞いは`SKILL.md`を参照。このREADMEは、使い始める前に人間が用意
すべき環境・Redmine側の設定をまとめたセットアップ手順。

## 必要なもの

- `curl`、`jq`
- Windows環境で実行する場合は、Git Bash等のbash実行環境

### 導入方法

- **Linux**: `curl`は多くのディストリビューションにプリインストール済み。`jq`は
  `apt install jq`（Debian/Ubuntu系）、`dnf install jq`（Fedora系）等でインストールする
- **macOS**: `curl`はプリインストール済み。`jq`は`brew install jq`（Homebrewが必要）
- **Windows**: [Git for Windows](https://gitforwindows.org/)をインストールし、Git Bashを使う
  （`curl`はGit Bashに同梱されている）。`jq`は同梱されていないため別途インストールが必要。
  `winget install jqlang.jq`または`scoop install jq`でインストールできる（`winget`のパッケージIDは
  変更される場合があるため、事前に`winget search jq`で確認すること）。インストール後はターミナルを
  再起動してから`jq --version`で確認する

## セットアップ

1. Claude Codeへ本スキルを配置する

   Claude Codeは、プロジェクトの`.claude/skills/<スキル名>/`、またはユーザーのホームディレクトリの
   `~/.claude/skills/<スキル名>/`に置かれたスキルを認識する。本リポジトリをcloneしただけではClaude
   Codeから見えないため、`install.sh`でスキル本体（`SKILL.md`・`scripts/`・`requirements.txt`・
   `*.example*`）を配置する。

   ```bash
   ./install.sh --user              # ユーザー全体で使う場合: ~/.claude/skills/redmine-tools-for-agents へ配置
   ./install.sh --project <path>    # 特定のプロジェクトでだけ使う場合: <path>/.claude/skills/redmine-tools-for-agents へ配置
   ```

   本リポジトリを更新した場合は、配置先を更新するために`install.sh`を再実行する（既存の配置先との
   差分を表示し、上書きしてよいか確認する）。

   GitHub Copilotで使う場合は、`--target copilot`を付けて実行する（`.claude/skills`ではなく
   `.copilot/skills`へ配置する）。

   ```bash
   ./install.sh --user --target copilot
   ./install.sh --project <path> --target copilot
   ```

2. `redmine-env.example`を元に`~/.config/redmine-env`を作成する（どのGitリポジトリの管理下にも
   置かず、コミットしないこと）

   ```bash
   cp redmine-env.example ~/.config/redmine-env
   ```

   - `REDMINE_URL`・`REDMINE_API_KEY`: 必須。接続先RedmineのURLとAPIキー。APIキーはRedmineの
     「個人設定」画面から取得できる。ユーザー個人のアカウントのAPIキーを使うと、コメント等の
     投稿者がユーザー本人かAIエージェントか区別できなくなるため、本スキルを使うAIエージェント専用の
     Redmineユーザーを作成し、そのAPIキーを使うことを推奨する
   - `REDMINE_HUB_PROJECT`・`REDMINE_REQ_INDEX_PAGE`: 任意。複数プロダクトでプロダクト識別子
     （プレフィックス）一覧を共有管理する場合のみ使用する（後述「プロダクト識別子一覧機能を
     使う場合」）。使わない場合はこの2行は不要（テンプレートのコメントアウトのままでよい）

3. （任意）独自の呼び名・プレフィックスを実際のRedmineプロジェクト識別子に対応付けたい場合は、
   `redmine-project-map.example.json`を元に`~/.config/redmine-project-map.json`を作成する

   ```bash
   cp redmine-project-map.example.json ~/.config/redmine-project-map.json
   ```

   このファイルは`{"各スクリプトに渡す任意の呼び名": "実際のRedmineプロジェクト識別子"}`という
   形式のJSONで、**キー（左側）**が`project_id`として各スクリプトに渡す値、**値（右側）**が
   実際のRedmineのプロジェクト識別子を表す。例えば以下のように書いておくと、
   `create_issue.sh MYPROJ ...`のように呼んだ際に、実際には`my-actual-project`という識別子の
   プロジェクトが使われる。

   ```json
   {
     "MYPROJ": "my-actual-project"
   }
   ```

   このファイルが無い場合、または該当するエントリが無い場合は、渡した識別子を小文字化した値が
   そのままプロジェクト識別子として使われる（例: `RTS` → `rts`）。

4. トラッカー・ステータスの役割マッピング（`~/.config/redmine-role-map.json`）は、本スキルが
   固定のトラッカー名・ステータス名を使わないために、プロジェクトごとに「役割名」と「実際の
   Redmine上の名前」を対応づけるファイル（詳細は`SKILL.md`の「トラッカー・ステータスの運用」を
   参照）。手動での準備は不要で、AIが対象プロジェクトへ初めてアクセスする際に、既存のトラッカー・
   ステータス一覧を確認して対応づけを提案し、承認を得たうえで自動的に作成・更新する（Redmine側で
   構成を変更して対応づけが無効になった場合も、AIが一覧を再確認し見直しを提案する）。

   初回アクセス時の提案・承認を待たず、あらかじめ手動で設定しておきたい場合のみ、
   `redmine-role-map.example.json`を元に作成する。

   ```bash
   cp redmine-role-map.example.json ~/.config/redmine-role-map.json
   ```

## Redmine側で事前に用意するもの

- **プロジェクト**: 操作対象のプロジェクトを作成しておく
- **トラッカー**: 通常のチケット用に1種類（既存の「課題」等をそのまま使ってよい）。ユーザー対応
  タスクの登録機能を使う場合はもう1種類（既存の「タスク」等）も有効化する
- **ステータス・ワークフロー**: 「新規」「着手」「完了」「却下」に相当するステータス（名前は既存の
  もので良い。例: 「新規」「対応中」「対応完了」「却下」）と、それらへの遷移（「新規」へ戻す遷移も
  含む）を含むワークフローを設定する
- **（オプション）カテゴリ機能**: APIキーに対応するユーザーに、対象プロジェクトの「チケットの
  カテゴリの管理」権限を付与する
- **（オプション）プロダクト識別子一覧機能を使う場合**: `REDMINE_HUB_PROJECT`に指定するプロジェクト
  でWikiモジュールを有効化し、APIキーに対応するユーザーにWikiの閲覧・編集権限を付与する
- **（オプション）役割マッピング**: `redmine-role-map.example.json`を元に
  `~/.config/redmine-role-map.json`を作成し、対象プロジェクトごとに対応づけを設定する
  （未設定の場合、AIが初回アクセス時に一覧を確認し、対応づけを提案する）

役割マッピング以外は、AIエージェント自身がこれらの設定を行うことはない。未設定の場合はエラー
メッセージとともに案内されるので、その都度このREADMEに従って用意する。

## 使い方

スキルとしての使い方・各スクリプトの詳細は[`SKILL.md`](SKILL.md)を参照。開発フロー（要件定義→設計→
実装等のSTEP区切り）と組み合わせた活用例は[`docs/example-step-workflow.md`](docs/example-step-workflow.md)
を参照。

## ライセンス

[MIT License](LICENSE)
