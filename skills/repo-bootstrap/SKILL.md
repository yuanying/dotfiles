---
name: repo-bootstrap
description: |
  リポジトリを作るときに必ず入れるもの (CI・テスト・リント・タグによるリリース・週次の自動リリース・Renovate・LICENSE・CLAUDE.md・ADR) を入れる。既存のリポジトリの点検と不足分の追加にも使う。
  トリガー: "repo-bootstrap", "/repo-bootstrap", "リポジトリを作って", "新しいリポジトリ", "リポジトリの初期設定", "CI を整えて", "リリースフローを入れて"
  使用場面: (1) 新しいリポジトリを作る、(2) 既存のリポジトリに足りないものを足す、(3) どこまで揃っているかを点検する
---

# リポジトリの初期設定

yuanying のリポジトリで揃えている作りを、新しいリポジトリにも入れる。
gated・cnidaria-cni・fraction-agents・porkadot で使ってきた形をまとめたもの。

## 原則

雛形の細部より、こちらを優先する。雛形が合わないときは、原則を守ったまま書き換える。

1. **`Makefile` が入口。** CI は make のターゲットを呼ぶだけで、CI でしか動かないものを作らない。
   `make help` でターゲットの一覧が出る。
2. **`make test` は言語のツールチェーンだけで通る。** クラスタ・root・外部サービスが要る
   テストは build tag か別ターゲットに分け、`make test` からは呼ばない。
3. **開発ツールの版はリポジトリが持つ。** Go なら `go.mod` の `tool` ディレクティブ、
   Node なら `devDependencies`、Ruby なら gemspec。グローバルには入れない。
4. **ワークフローの権限は最小にする。** ファイルの先頭は `permissions: contents: read` (または `{}`)。
   書き込みの権限は、それが要るジョブにだけ付ける。CI では stored secret を使わない。
5. **Actions はメジャー版のタグで参照する** (`actions/checkout@v7`)。SHA では固定しない。
   メジャーが上がったら Renovate が PR を出す。
6. **設定には理由を書く。** ワークフローや Makefile はコメントで、`renovate.json` は各ルールの
   `description` で。「なぜそうなっているか」が無い設定は、後で消してよいのか判断できない。

## チェックリスト

| 項目 | 置くもの | 備考 |
|---|---|---|
| デフォルトブランチ | `main` | |
| LICENSE | `LICENSE` | 既定は MIT、`Copyright (c) <年> yuanying`。迷ったらユーザーに聞く |
| README | `README.md` | 何をするものか、使い方、`make help` |
| エージェント向けの指示 | `CLAUDE.md` | テストの層、守るべき取り決め、ADR の場所 |
| ADR | `docs/adr/NNNN-<slug>.md` | 最初の設計判断を `0001` に。`adr-manager` スキルを使う |
| `.gitignore` | `.gitignore` | 生成物 (`bin/`、`dist/`) |
| 入口 | `Makefile` | `help`・`fmt`・`fmt-check`・`vet`・`lint`・`test`・`tidy`・`build`・`dist` |
| フォーマット | `make fmt` / `make fmt-check` | Go は gofmt。CI の `fmt-check` で落とす |
| リント | `make lint` | Go は golangci-lint v2 (最小構成から始める) |
| テスト | `make test` | 少なくとも 1 本のテストを書いて CI が実際に走ることを確かめる |
| 脆弱性検査 | `make vuln` | Go は govulncheck |
| CI | `.github/workflows/ci.yml` | push to main と全 PR。paths フィルタは付けない (自動マージの前提) |
| タグでのリリース | `.github/workflows/release.yml` | `v*.*.*` の push で、成果物を GitHub Release に、イメージを ghcr.io に |
| 週次の自動リリース | `.github/workflows/weekly-release.yml` と `.github/scripts/plan-release.sh` | Renovate のコミットだけなら毎週月曜にパッチ版を出す |
| 依存の更新 | `renovate.json` | 共通の preset `yuanying/renovate-config` を extends する。patch と digest の自動マージ、Actions を 1 つの PR にまとめるのは preset が持つ |
| GitHub の設定 | `gh repo edit` | マージ後にブランチを消す。Renovate App がそのリポジトリで有効か |

## 雛形

雛形はこの SKILL.md と同じディレクトリの `templates/` にある。このスキルは symlink 越しに
読み込まれるので、**読み込んだパスを `readlink -f` で解決し、その親ディレクトリを使う。**
`~/dotfiles` を決め打ちしない。

```text
templates/
  common/                          どの言語でも使う
    renovate.json
    .github/workflows/weekly-release.yml
    .github/scripts/plan-release.sh
  go/
    Makefile  .golangci.yml  .gitignore
    .github/workflows/ci.yml
    .github/workflows/release.yml
```

`__APP__` はリポジトリ名 (= `cmd/<名前>` のバイナリ名) に置き換える。

## 手順

### 1. 状況を確かめる

次の点を確かめる。リポジトリから読み取れないものはユーザーに聞く。

- 新しく作るのか、既存のリポジトリに足すのか
- 言語
- 何をリリースするか: CLI のバイナリ、コンテナイメージ、その両方、ライブラリ (タグだけ)、何も無い
- LICENSE (MIT か Apache-2.0 か)
- 公開か非公開か

既存のリポジトリなら、まずチェックリストと突き合わせて、何があって何が無いかを表にして見せる。
すでにある CI やリリースの仕組みは、黙って置き換えない。何をどう変えるかを提案して、了承を得てから変える。

### 2. ブランチを切る

既存のリポジトリなら、デフォルトブランチの最新から作業ブランチを切る。新しいリポジトリでも
最初のコミット (README と LICENSE) の後は同じようにする。チェックリストの項目ごとにコミットを分ける。

### 3. 雛形を置いて書き換える

`templates/common/` と言語のディレクトリから必要なものをコピーし、`__APP__` を置き換える。
`plan-release.sh` には実行権限を付ける (`chmod +x`)。

雛形をそのまま使えない部分:

- **リリースするものに合わせて `release.yml` を削る。**
  - イメージを出さないなら、`image` ジョブを消し、`release` ジョブの `needs` からも外す。
    `weekly-release.yml` の `packages: write` も消す。
  - バイナリを出さないなら、`dist` ジョブを消す。`gh release create` の `dist/*` と
    `download-artifact` も消す。
- **リリースに入らないファイル。** `plan-release.sh` の `RELEASE_IGNORE` は既定で
  `.github/`・`renovate.json`・`docs/`・`*.md` を除く。テストのフィクスチャや `hack/` などを
  除きたければ、`weekly-release.yml` の `plan` ステップで `env: RELEASE_IGNORE` を設定する。
- **デフォルトブランチが `main` でない**なら、`ci.yml` の `branches` を合わせる。
- **Renovate の共通の設定は `yuanying/renovate-config` の preset にある。** 雛形の `renovate.json` は
  それを extends するだけ。リポジトリだけのルール (`node` グループ、`pinDigests` など) は、
  そのリポジトリの `packageRules` に足す。preset のルールより後に当たるので、preset の値も上書きできる。
  人がマージするまで待たせたいリポジトリは、`:automerge-patch` を extends から外す。
  preset を変えると全リポジトリに効くので、リポジトリ一つのための変更は preset に入れない。

### 4. 言語ごとの作業

#### Go

```bash
go mod init github.com/yuanying/<repo>
go get -tool github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
go get -tool golang.org/x/vuln/cmd/govulncheck@latest
```

- エントリポイントは `cmd/<app>/main.go`。`make build` と `make dist` は
  `-X main.version=$(VERSION)` を渡すので、`main` パッケージに `var version = "dev"` を置く。
- `renovate.json` に `"postUpdateOptions": ["gomodTidy"]` を足す。CI の `tidy` ジョブは、
  これがあることを前提にしている。
- Kubernetes のライブラリ (`k8s.io/*`、controller-runtime、controller-tools) を使うなら、
  gated の `renovate.json` と同じように `kubernetes monorepo` グループにまとめる。
- コンテナイメージを出すなら Dockerfile は multi-stage にし、`ARG VERSION` を受けて
  `-X main.version` に渡す。
- リンターを足すのは、その種類の間違いが実際に起きてから。足すときはコメントで理由を書く。

#### TypeScript (Node)

雛形は無い。fraction-agents を見本にする。

- `package.json` の scripts に `typecheck`・`test`・`build` を置き、CI は `npm ci` の後に
  これらを呼ぶ。この場合 Makefile は無くてよい (`npm run` が入口)。
- `setup-node` には `node-version` を版付きで書く。Dockerfile の `FROM node:` の版と合わせ、
  Renovate の `node` グループで同じ PR にまとめる (fraction-agents の `renovate.json` を参照)。
- 週次リリースの判定は `plan-release.sh` をそのまま使える。

#### Ruby

雛形は無い。porkadot を見本にする。CI は `ruby/setup-ruby@v1` に `bundler-cache: true` を付け、
`bundle exec rake test` を呼ぶ。版を書き換えて commit してからタグを打つ必要がある gem では、
porkadot の `.github/scripts/weekly_release.rb` の形を使う (`plan-release.sh` はタグを打つだけ)。

### 5. 手元で確かめる

push する前に、CI と同じものを手元で通す。

```bash
make help
make fmt-check vet lint test tidy vuln
git status --porcelain                     # tidy の後に差分が無いこと
make dist VERSION=v0.0.0-local && ls dist  # バイナリを出すなら
actionlint                                 # 入っていれば
npx --yes --package renovate -- renovate-config-validator
.github/scripts/plan-release.sh            # タグが無ければ "no release" になる
```

### 6. GitHub に出す

ここから先は外に出る操作なので、**一つずつユーザーの了承を得てから行う。**

1. リポジトリを作る: `gh repo create yuanying/<repo> --public|--private --source . --push`
2. 設定: `gh repo edit yuanying/<repo> --delete-branch-on-merge`
3. Renovate: Renovate App がこのリポジトリで有効かをユーザーに確かめてもらう。
   有効なら onboarding PR か Dependency Dashboard の issue が届く。
4. 最初のリリース: 週次リリースは前回の `vX.Y.Z` タグを起点にするので、タグが無いと
   いつまでも何も出さない。最初の `v0.1.0` は手で打つ:
   `git tag -a v0.1.0 -m "v0.1.0" && git push origin v0.1.0`
5. Actions の実行結果を `gh run list` / `gh run watch` で確かめ、失敗したら直す。

## 週次の自動リリースの仕組み

- `weekly-release.yml` が毎週月曜 09:00 JST (と手動実行) に `plan-release.sh` を走らせる。
- 前回の `vX.Y.Z` 以降のコミット (マージコミットを除く) が**すべて `renovate[bot]` のもので**、
  かつ `RELEASE_IGNORE` 以外のファイルを変えていれば、次のパッチ版を出す。人のコミットが
  1 つでもあれば何もせず、手でタグを打つのに任せる。
- `GITHUB_TOKEN` で push したタグは他のワークフローを起動しないので、`release.yml` を
  `workflow_call` で直接呼ぶ。`release.yml` はビルドとイメージの push がすべて済んでから
  タグを打つので、途中で失敗してもタグは残らない。
- Renovate の自動マージ (preset の `automerge-patch`。patch と digest) と組み合わせて、依存の更新は人の手を介さずにリリースまで届く。
  minor と major は PR が開くだけで、マージは人が行う。
