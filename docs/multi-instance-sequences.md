# 複数Redmineインスタンス対応のシーケンス

複数のRedmineインスタンスを設定している場合に、AIエージェントが本スキルのスクリプトを
どのような流れで呼び出すかを示す。設定方法・各スクリプトの詳細な使い方は
[`SKILL.md`](../SKILL.md)の「複数のRedmineインスタンスを扱う場合」、
セットアップ手順は[`setup.md`](setup.md)を参照。

## 通常のスクリプト呼び出し

対象インスタンスは、呼び出し時に`REDMINE_INSTANCE=<NAME>`を前置して指定する。省略した場合は
`REDMINE_DEFAULT`、次に接尾辞なしの`REDMINE_URL` / `REDMINE_API_KEY`の順でデフォルトインスタンス
が使われる。どちらも無ければエラーになる。

```mermaid
sequenceDiagram
    actor User as ユーザー
    participant AI as AIエージェント
    participant Script as redmine-tools-for-agents\nスクリプト
    participant Redmine as Redmine API

    User->>AI: チケット#101の内容を教えて
    AI->>AI: 会話の文脈から対象インスタンスを判断

    alt 文脈から対象インスタンスが明らかな場合
        AI->>Script: REDMINE_INSTANCE=HOME ./get_issue.sh 101
    else 文脈から特定できない／デフォルトで問題ない場合
        AI->>Script: ./get_issue.sh 101（REDMINE_INSTANCE省略）
    end

    Script->>Script: 対象インスタンスを解決\n（REDMINE_INSTANCE→REDMINE_DEFAULT→接尾辞なし設定の順）

    alt 解決成功
        Script->>Redmine: GET /issues/101.json\n（X-Redmine-API-Key付き）
        Redmine-->>Script: 200 OK + チケット本文
        Script-->>AI: 対象インスタンス: HOME (https://...)\nチケット本文
        AI-->>User: チケット#101の内容を表示
    else 認証失敗（401。インスタンスを取り違えたAPIキー等）
        Script->>Redmine: GET /issues/101.json
        Redmine-->>Script: 401 Unauthorized
        Script-->>AI: エラー: Redmineの認証に失敗しました。対象インスタンスの設定またはAPIキーを確認してください
        AI-->>User: エラーを報告し、設定確認を依頼
    else 対象インスタンスを特定できない（何も設定されていない）
        Script-->>AI: エラー: REDMINE_INSTANCEを指定してください。list_instances.shで確認できます
        AI->>Script: ./list_instances.sh
        Script-->>AI: 設定済みインスタンス一覧（名前・URL）
        AI-->>User: どのインスタンスを使うか確認
    end
```

## REDMINE_HUB_PROJECT・REDMINE_REQ_INDEX_PAGEを扱う場合

プロダクト識別子（プレフィックス）一覧機能（`get_req_index.sh` / `update_req_index.sh`）は、
複数インスタンス対応後も常にデフォルトインスタンスのみを対象とする。`REDMINE_INSTANCE`を
指定しても無視され（指定していれば、無視される旨の警告が表示される）、他インスタンスへ
切り替えることはできない。

```mermaid
sequenceDiagram
    actor User as ユーザー
    participant AI as AIエージェント
    participant Script as get_req_index.sh /\nupdate_req_index.sh
    participant Redmine as Redmine API

    Note over AI: 他の作業でREDMINE_INSTANCE=WORKを使っている文脈

    User->>AI: 新しいプロダクト識別子をREQ_INDEXへ登録して
    AI->>Script: REDMINE_INSTANCE=WORK ./get_req_index.sh out.txt
    Script->>Script: 対象インスタンスを解決\n（REDMINE_INSTANCEは無視。REDMINE_DEFAULT→接尾辞なし設定の順）
    Script-->>AI: 警告: REDMINE_HUB_PROJECT機能は常にデフォルトインスタンスに対して動作するため、\nREDMINE_INSTANCE=WORK は無視されます。\n対象インスタンス: HOME (https://...)
    Script->>Redmine: GET /projects/hub-pj/wiki/REQ_INDEX.json
    Redmine-->>Script: 200 OK + ページ本文・版番号
    Script-->>AI: ページ本文（out.txtへ保存）・版番号

    AI->>AI: 取得した本文に新しい識別子の行を追記\n（1回目の警告から、本機能はREDMINE_INSTANCEを無視する仕様と判断し、以降は付けない）
    AI->>Script: ./update_req_index.sh out.txt <版番号> "コメント"（REDMINE_INSTANCE省略）
    Script->>Script: 対象インスタンスを解決\n（REDMINE_INSTANCE未指定のため警告なし。REDMINE_DEFAULT→接尾辞なし設定の順）
    Script-->>AI: 対象インスタンス: HOME (https://...)
    Script->>Redmine: PUT /projects/hub-pj/wiki/REQ_INDEX.json
    Redmine-->>Script: 200 OK
    Script-->>AI: 更新完了
    AI-->>User: REQ_INDEXへの登録が完了したことを報告\n（対象はHOME。現在作業中のWORKではないことも伝える）

    Note over AI: REDMINE_INSTANCEの省略は、get_req_index.sh・update_req_index.shに限った話である。\nそれ以外のスクリプト呼び出し（チケット作成・コメント追記等）では、\n引き続きREDMINE_INSTANCE=WORKを明示し続ける（省略するとデフォルト（HOME）に\n切り替わってしまうため、WORK側の作業中は省略してはならない）
```
