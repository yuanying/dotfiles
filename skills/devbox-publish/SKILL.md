---
name: devbox-publish
description: |
  devbox 上で起動した HTTP サーバーを https://<name>.<zone> に恒久登録する / 登録を解除する。
  トリガー: "devbox-publish", "/devbox-publish", "公開して", "publish", "このサーバーを外から見えるように", "公開をやめて"
  使用場面: (1) llama-server などを立てた後にブラウザから使えるようにする、(2) 公開の取り消し、(3) いま何を公開しているかの確認
---

# devbox のサーバーを公開する

devbox で立てた HTTP サーバーを、Cloudflare Access の GitHub ログイン越しに
`https://<name>.<zone>` で公開する。**恒久登録**であり、一時的なトンネルでは
ない。宣言ファイルへの追記・Cloudflare の DNS と Access アプリ・プロキシの
リロードまでを行う。

仕組みと設計理由は `devbox/proxy/README.md` と `docs/adr/0001`〜`0004` にある。
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
  （Universal SSL とワイルドカード Origin CA がどちらも 1 階層で止まるため。
  `docs/adr/0002`）。名前空間が欲しければ `gpu-llama` のようにする。
- ゾーンはホストごとに違う。anietta は `oeilvert.dev`、boucherie は
  `poissonnerie.dev`。したがって両ホストで同じサービス名を使ってよい。

### 2. 誰に見せるかを決める

`auth: required`（既定）なら **許可する相手を最低 1 つ**挙げる必要がある。
許可ルールの無い Access アプリは自分を含む全員を締め出すので、指定が無ければ
エラーになる。ユーザーに確認して決めること。

- `--email <アドレス>` — 個人を指定する
- `--github-org <組織名>` — GitHub organization のメンバー全員を許可する

`--auth none` は**ログイン無しで全世界に公開する**。オリジンの IPv6 に直接
来たリクエストも通る。それでよい対象にだけ使い、必ずユーザーに確認する。

### 3. 登録する

```bash
bin/devbox-publish publish --name llama --port 8081 --github-org acme
```

やることは順に、宣言ファイルへの追記 → Cloudflare の反映 → プロキシのリロード。

`CLOUDFLARE_API_TOKEN` が環境にあれば最後まで自動で通る。DNS の AAAA レコードと
Access アプリが作られ、Cloudflare が発行した audience タグが宣言ファイルへ
書き戻される。

**トークンは常駐しない**（`docs/adr/0002`）。無い場合はエラーにはならず、
宣言ファイルへの追記までを済ませて、残りを具体的なコマンドとして表示して
止まる。その出力をそのままユーザーに渡し、トークンを用意してもらうこと。
勝手にトークンを探しに行ったり、リポジトリに書き込んだりしない。

### 4. コミットを促す

audience タグは宣言ファイルに書き戻され、オリジンが毎リクエスト照合する。
**識別子であって秘密ではないので、コミットする。** 出力の最後に出る
`git -C ... commit` を実行してよいかユーザーに確認する。

## 登録を解除する

```bash
bin/devbox-publish unpublish --name llama
```

宣言ファイルから消し、トークンがあれば `sync-cloudflare.sh --prune` で
DNS レコードと Access アプリを削除し、リロードする。トークンが無ければ
`publish` と同じく、残りのコマンドを表示して止まる。

`--prune` の安全策（このホストのゾーンの `<ラベル>.<ゾーン>` 形式で、かつ
proxied なレコードだけを消す）は迂回しないこと。手で API を叩いて消さない。

## いま何を公開しているか

```bash
bin/devbox-publish list
```

プロキシ自体の状態（Traefik が動いているか、証明書の期限）は
`devbox/proxy/bin/devbox-proxy status` が答える。

## 注意

- プロキシがリロードされない場合がある。`auth: required` のサービスは
  audience タグが埋まるまで Traefik 設定を生成できないため、`reload` は
  意図的に見送られる。**動いている他のサービスを止めないための挙動**であって
  失敗ではない。Cloudflare の反映が済めば次の `reload` で通る。
- dotfiles は public リポジトリ。API トークン・秘密鍵・その他の資格情報を
  宣言ファイルやコミットに含めない。
- 証明書がまだ無いホストでは公開は成立しない。
  `devbox/proxy/bin/issue-origin-cert.sh` が要る（ゾーンごとに 1 枚）。
  手順は `devbox/proxy/README.md` の One-time setup にある。
