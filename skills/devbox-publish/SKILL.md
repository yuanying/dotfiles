---
name: devbox-publish
description: |
  devbox 上で起動した HTTP サーバーを https://<name>.<zone> に恒久登録する / 登録を解除する。
  トリガー: "devbox-publish", "/devbox-publish", "公開して", "publish", "このサーバーを外から見えるように", "公開をやめて"
  使用場面: (1) llama-server などを立てた後にブラウザから使えるようにする、(2) 公開の取り消し、(3) いま何を公開しているかの確認
---

# devbox のサーバーを公開する

devbox で立てた HTTP サーバーを、GitHub ログイン越しに `https://<name>.<zone>`
で公開する。**恒久登録**であり、一時的なトンネルではない。宣言ファイルへの
追記とプロキシのリロードまでを行う。

仕組みと設計理由は `devbox/proxy/README.md` と `docs/adr/0004`〜`0008` にある。
このスキルはその運用手順を実行するだけで、判断は変えない。

## 使うコマンド

このスキルのディレクトリにある `bin/devbox-publish` を使う。**スキルは
`~/.claude/skills/devbox-publish` 経由で読み込まれ、そこは symlink なので、
`~/dotfiles` を決め打ちしてはいけない。** スクリプト自身が自分の実体の位置から
dotfiles チェックアウトを割り出し、`devbox/proxy/services.$(hostname -s).yaml`
を引く。つまり **このスキルの `bin/devbox-publish` を相対パスで呼ぶだけでよい**。

```bash
"$(dirname "$0")/bin/devbox-publish" where
```

迷ったら最初に `where` を実行して、どのチェックアウトのどの宣言ファイルを
触ろうとしているのかをユーザーに見せること。

## 手順

### 1. 前提を確かめる

- サーバーが **`127.0.0.1:<port>` で listen している**こと。プロキシはそこへ
  繋ぐ。グローバル IPv6 だけに bind されたサーバーは公開できない。
  `publish` は既定でこれを検査し、繋がらなければ何も書かずに止まる。
- 公開名は **DNS ラベル 1 つ**。`llama` は可、`llama.gpu` は不可
  （ワイルドカードの AAAA レコードが 1 階層までしかカバーしないため。
  `docs/adr/0006`）。名前空間が欲しければ `gpu-llama` のようにする。
- **`auth` は予約名**。`auth.<zone>` は GitHub ログインが行われるホストで、
  サービス名には使えない（`docs/adr/0007`）。
- ゾーンはホストごとに違う。anietta は `oeilvert.dev`、boucherie は
  `poissonnerie.dev`。したがって両ホストで同じサービス名を使ってよい。

### 2. 誰に見せるかを決める

`auth: required`（既定）なら **許可する相手を最低 1 つ**挙げる必要がある。
誰も許可しないサービスは自分を含む全員を締め出すので、指定が無ければ
エラーになる。ユーザーに確認して決めること。

- `--github-login <アカウント名>` — GitHub アカウント名で個人を指定する
- `--github-org <組織名>` — GitHub organization のメンバー全員を許可する

**メールアドレスでは指定できない**。照合は GitHub のアカウント名で行う
（`docs/adr/0007`）。ユーザーがメールアドレスを言ってきたら、対応する GitHub
アカウント名を確認すること。

**`--github-login` で指定した名前は public リポジトリにコミットされる。**
本人以外を追加するときは、その名前を公開してよいかユーザーに確認すること。

`--auth none` は**ログイン無しで全世界に公開する**。devbox の IPv6 は DNS に
出ており、ホスト名も証明書の透明性ログから辿れるので、これは文字通り誰にでも
公開される。それでよい対象にだけ使い、必ずユーザーに確認する。

### 3. 公開したくない場合

サービスの存在自体、あるいは許可者の名前を public リポジトリに残したくない
場合は、`~/.config/devbox-proxy/services.local.yaml` に書く（`docs/adr/0009`）。
宣言ファイルと同じスキーマで、**マージ**される。

```yaml
# ~/.config/devbox-proxy/services.local.yaml — リポジトリの外、コミットされない
services:
  # 宣言ファイルにあるサービスに人を足す
  - name: llama
    viewers:
      logins:
        - someone

  # 宣言ファイルに存在しないサービスを公開する
  - name: private
    port: 9000
    auth: required
    viewers:
      logins:
        - yuanying
```

書いたら `devbox/proxy/bin/devbox-proxy reload` で反映される。

**このスキルはこのファイルを編集しない。** `publish` は必ず宣言ファイル
（＝public）に書く。非公開にしたい場合は上の手順を示してユーザーに任せるか、
明示的に指示された場合のみ編集すること。どちらに書くべきかは、サービスや
許可者を公開してよいかで決まるので、**ユーザーに確認すること**。

### 4. 登録する

```bash
bin/devbox-publish publish --name llama --port 8081 --github-org acme
```

やることは宣言ファイルへの追記とプロキシのリロードだけ。**API トークンも
外部サービスへの登録も要らない**（`docs/adr/0005`）。証明書は初回アクセス時に
Let's Encrypt から自動で取得される。

途中で止まって続きを人手に委ねる、という状態は無い。成功するか、理由を出して
失敗するかのどちらか。

### 5. コミットを促す

宣言ファイルはプロキシの設定そのものなので、変更はコミットする。秘密は
含まれないが、**viewers に書いた GitHub アカウント名は公開される**ことを
忘れないこと。出力の最後に出る `git -C ... commit` を実行してよいか
ユーザーに確認する。

## 登録を解除する

```bash
bin/devbox-publish unpublish --name llama
```

宣言ファイルから消してリロードする。ワイルドカードの DNS レコードは残るが
（元々全ラベル共通のものなので）、その名前には何も応答しなくなり、証明書も
更新されなくなる。Cloudflare 側で消すものは何も無い。

## いま何を公開しているか

```bash
bin/devbox-publish list
```

プロキシ自体の状態（起動しているか、証明書の期限、直近の更新が成功したか）は
`devbox/proxy/bin/devbox-proxy status` が答える。

## 注意

- dotfiles は public リポジトリ。秘密鍵や資格情報を宣言ファイルやコミットに
  含めない。`~/.config/devbox-proxy/` にある `session.key` と `github.yaml` は
  リポジトリの外にあり、そこから動かさない。
- **初回のみ、`~/.config/devbox-proxy/github.yaml` に GitHub OAuth App の
  資格情報が必要**。無い状態で `auth: required` のサービスを公開すると、
  プロキシは起動するがログインが完了しない。手順は
  `devbox/proxy/README.md` の One-time setup にある。
- 証明書は事前準備が要らない。まだ発行されていないホストは
  `devbox-proxy status` に `pending` と出るが、それは異常ではなく、最初の
  アクセスで発行される。
- **何が公開されていて誰が入れるかは `devbox/proxy/bin/devbox-proxy check` が
  答える。** 宣言ファイルと `services.local.yaml` をマージした結果を出す。
  宣言ファイルだけを読んで「このサービスは無い」「この人は入れない」と判断
  しないこと。`list` は宣言ファイルしか見ないので、全体を知るには `check`。
