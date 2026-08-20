# CLAUDE.md

## Branch Strategy

**このリポジトリのデフォルトブランチは `lua`。**

グローバル設定 (`~/.claude/CLAUDE.md`) の Branch Strategy は `main` を前提に
しているが、このリポジトリではそれを `lua` に読み替えること。

- 新しくブランチを切るときは `origin/lua` を起点にする
- Pull Request のベースブランチは `lua`
- `master` は移行前の旧デフォルトブランチ。現在の開発はすべて `lua` で進んで
  いるので、指示が無い限り `master` に対して作業やマージを行わないこと

## skills/

エージェントが読むスキル。`bin/setup-skills.sh` が `~/.agents/skills` と
`~/.claude/skills` の両方へ symlink を張る (`bin/setup.sh` から呼んでいる)。
作法は `yuanying/skills` の `scripts/install-skills.sh` に揃えてあり、衝突を
見つけたら 1 つも張らずに中止する。

- **Important** スキルは symlink 越しに読み込まれる。スキルからこのリポジトリ内の
  他のファイルを参照するときは、**自分の実体の位置から解決すること**。
  `~/dotfiles` を決め打ちしてはいけない (チェックアウトはそこにあるとは限らず、
  worktree では中身も違う)。
- テストは `test/`。リポジトリ全体のテストは root で `bats -r .` を実行する
  (`test/` と `devbox/proxy/test/` の両方が走る)。

## devbox/

開発環境の Docker イメージ。旧 `yuanying/devbox` リポジトリを取り込んだもので、
詳細は `devbox/CLAUDE.md` にある。以下はこのディレクトリを越えて効く取り決め。

- ピン留めしたバージョンの正は `devbox/Dockerfile` の `ARG <NAME>_VERSION`。
  Renovate が追うのはそこだけなので、他のどこにも書き写さない。
  `bin/mac/setup-packages.sh` は必要な ARG をあのファイルから読み出している。
- Renovate の設定 `renovate.json` はリポジトリのルートに置く (Renovate が
  ルートしか読まないため)。`devbox/` 配下のファイルはパス付きで指定してある。
- `devbox/LICENSE` は MIT。リポジトリ全体の Apache-2.0 とは別なので消さない。
