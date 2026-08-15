# CLAUDE.md

## Branch Strategy

**このリポジトリのデフォルトブランチは `lua`。**

グローバル設定 (`~/.claude/CLAUDE.md`) の Branch Strategy は `main` を前提に
しているが、このリポジトリではそれを `lua` に読み替えること。

- 新しくブランチを切るときは `origin/lua` を起点にする
- Pull Request のベースブランチは `lua`
- `master` は移行前の旧デフォルトブランチ。現在の開発はすべて `lua` で進んで
  いるので、指示が無い限り `master` に対して作業やマージを行わないこと
