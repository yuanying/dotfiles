# pi/

[pi coding agent](https://github.com/earendil-works/pi) の設定。devbox でも Mac でも
`bin/setup.sh` から呼ばれる `bin/setup-pi.sh` が `~/.pi/agent` へ流し込む。

| 置くもの | 置き場所 | 流し込み方 |
|---|---|---|
| 設定 | `settings.json`、ホスト別は `settings.<hostname>.json` | 手元 < 共通 < ホスト別 の順に jq でマージ。pi が書き戻すので symlink にしない |
| Web 検索 (pi-web-access) | `web-search.json`、ホスト別は `web-search.<hostname>.json` | 同上。pi-web-access も書き戻す |
| パッケージ (他人の extension) | `settings.json` の `packages` に `npm:<名前>@<版>` で書く | マージの後に `pi install` で入れる。版は Renovate が追う |
| 自作の extension | `extensions/` に単体の `.ts` か、`index.ts` を持つディレクトリ | 1 つずつ symlink |
| テーマ | `themes/<名前>.json` (`name` はファイル名と同じ) | 1 つずつ symlink。どれを使うかは各ホストの `settings` の `theme` |
| プロンプトテンプレート | `prompts/*.md` | 1 つずつ symlink |

- スキルはここに置かない。pi は `~/.agents/skills` も読むので、リポジトリ直下の
  `skills/` が `bin/setup-skills.sh` 経由でそのまま届く。
- ユーザー指示は Claude Code と同じ `~/.claude/CLAUDE.md` を `~/.pi/agent/CLAUDE.md`
  として張る (pi 用の `AGENTS.md` / `CLAUDE.md` を手で置いたホストでは張らない)。
- `extensions/` を丸ごと symlink にしないのは、`herdr integration install pi` と
  `moshi-hook install` が同じディレクトリに自分のファイルを置くため。
- `auth.json` とセッションはホストごとのまま。ログインは各ホストで `/login` を 1 回。
- 本体の版は `devbox/Dockerfile` の `ARG PI_VERSION`。Mac では
  `bin/mac/setup-packages.sh` がそれを読んで同じ版を npm で入れる。

自作の extension を足したら、各ホストで `bin/setup-pi.sh` を流すか (devbox は
起動時に流れる)、既に張ってあるものを直しただけなら pi で `/reload` する。
