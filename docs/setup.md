# セットアップ

本スキルを使い始める前に人間が用意すべき環境・Redmine側の設定をまとめる。スキルとしての
使い方・AIの振る舞いは[`SKILL.md`](../SKILL.md)を参照。

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

## セットアップ手順

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

   接続先Redmineが1つだけの場合も、複数ある場合も、名前（`<NAME>`）を付けた形式
   `REDMINE_URL_<NAME>` / `REDMINE_API_KEY_<NAME>`で設定することを推奨する。`<NAME>`は
   英数字・アンダースコアのみ使用可。APIキーはRedmineの「個人設定」画面から取得できる。

   `REDMINE_AI_SIGNATURE_<NAME>`は任意（`redmine-env.example`参照）。本スキル専用の
   Redmineユーザーを使用していない場合は設定せず、既定値の`true`のままにすることを推奨する。

   - **Redmineが1つだけの場合**: 名前を1つ決め（例: `HOME`）、`REDMINE_DEFAULT`にその名前を
     指定する。

     ```bash
     export REDMINE_URL_HOME="https://redmine.example.com"
     export REDMINE_API_KEY_HOME="your-api-key-here"
     export REDMINE_DEFAULT="HOME"
     ```

     こうしておくと、後から2つ目のRedmineインスタンスを追加したくなった場合に、下記のように
     接尾辞付きの変数を増やすだけで済む。

   - **Redmineが複数ある場合（例: 自宅用と仕事用）**: 上記に加えて、2つ目以降のインスタンスを
     同様の形式で追加する。

     ```bash
     export REDMINE_URL_HOME="https://redmine.example.com"
     export REDMINE_API_KEY_HOME="your-api-key-here"
     export REDMINE_URL_WORK="https://redmine.work.example.com"
     export REDMINE_API_KEY_WORK="your-work-api-key-here"
     export REDMINE_DEFAULT="HOME"
     ```

     `REDMINE_INSTANCE=<NAME>`を省略して呼び出した場合は`REDMINE_DEFAULT`で指定したインスタンス
     （上記の例では`HOME`）が使われ、`REDMINE_INSTANCE=WORK`を前置して呼び出すとそちらが
     使われる。設定済みインスタンスの一覧は`list_instances.sh`で確認できる。呼び出し方の詳細は
     `SKILL.md`の「複数のRedmineインスタンスを扱う場合」を参照

   - **（後方互換）名前を付けない形式**: 接尾辞を付けず、`REDMINE_URL`・`REDMINE_API_KEY`
     だけを設定する形式も引き続き使用できる（既存ユーザーはこの形式のままで変更不要）。新規に
     導入する場合は、上記の名前付き設定を使うことを推奨する

   - **（任意）`REDMINE_HUB_PROJECT`・`REDMINE_REQ_INDEX_PAGE`**: 複数プロダクトでプロダクト
     識別子（プレフィックス）一覧を共有管理する場合のみ使用する（後述「プロダクト識別子一覧機能を
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

4. （任意）トラッカー・ステータスの役割マッピング（`~/.config/redmine-role-map.json`）をあらかじめ
   手動で設定する

   本スキルは固定のトラッカー名・ステータス名を使わないため、プロジェクトごとに「役割名」と
   「実際のRedmine上の名前」を対応づけるファイルが必要になる（詳細は`SKILL.md`の
   「トラッカー・ステータスの運用」を参照）。**手動での準備は不要**で、AIが対象プロジェクトへ
   初めてアクセスする際に、既存のトラッカー・ステータス一覧を確認して対応づけを提案し、承認を
   得たうえで自動的に作成・更新する（Redmine側で構成を変更して対応づけが無効になった場合も、
   AIが一覧を再確認し見直しを提案する）。

   初回アクセス時の提案・承認を待たず、あらかじめ手動で設定しておきたい場合のみ、以下のように
   作成する。

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
- **（任意）カテゴリ機能**: APIキーに対応するユーザーに、対象プロジェクトの「チケットの
  カテゴリの管理」権限を付与する
- **（任意）プロダクト識別子一覧機能を使う場合**: `REDMINE_HUB_PROJECT`に指定するプロジェクト
  でWikiモジュールを有効化し、APIキーに対応するユーザーにWikiの閲覧・編集権限を付与する
