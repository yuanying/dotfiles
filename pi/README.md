# pi/

[pi coding agent](https://github.com/earendil-works/pi) の設定。devbox でも Mac でも
`bin/setup.sh` から呼ばれる `bin/setup-pi.sh` が `~/.pi/agent` へ流し込む。

| 置くもの | 置き場所 | 流し込み方 |
|---|---|---|
| 設定 | `settings.json`、ホスト別は `settings.<hostname>.json` | 手元 < 共通 < ホスト別 の順に jq でマージ。pi が書き戻すので symlink にしない |
| キーバインド | `keybindings.json`、ホスト別は `keybindings.<hostname>.json` | 設定と同じ順でマージ |
| Web 検索 (pi-web-access) | `web-search.json`、ホスト別は `web-search.<hostname>.json` | 同上。pi-web-access も書き戻す |
| パッケージ (他人の extension) | `settings.json` の `packages` に `npm:<名前>@<版>` で書く | マージの後に `pi install` で入れる。版は Renovate が追う |
| 自作の extension | `extensions/` に単体の `.ts` か、`index.ts` を持つディレクトリ | 1 つずつ symlink |
| テーマ | `themes/<名前>.json` (`name` はファイル名と同じ) | 1 つずつ symlink。どれを使うかは各ホストの `settings` の `theme` |
| プロンプトテンプレート | `prompts/*.md` | 1 つずつ symlink |

- 選択リストは矢印キーに加えて `Ctrl+p` / `Ctrl+n` で上下移動する。
  競合する既定キーは、モデルの次 / 前を `Alt+n` / `Alt+p`、
  `/resume` のパス表示 / 名前付きフィルタを `Alt+p` / `Alt+n`、
  `/scoped-models` のプロバイダー一括切替を `Alt+p` に変更している。
- 入力欄の履歴は `Ctrl+p` / `Ctrl+n` で前 / 次へ移動する。
- `Ctrl+[` も選択画面のキャンセルと生成中の中断に使える (`Esc` はそのまま)。
- 利用率表示は `@specode/pi-subscription-usage` を使う。フッターの `1w` が週間使用率。
  `subscription-usage.json` の `displayMode: "used"` で消費した割合を表示する
  (設定は他の JSON と同じ順でマージ)。`/usage` で詳細表示・再取得する。
  `openai` の ChatGPT サブスクリプションでは、同じアカウント・ワークスペースで
  `/login openai-codex` も一度行う。Codex 認証は Usage の取得だけに使い、
  モデルは `openai` のままでよい。プラン全体とアプリ別の制限は別々に表示する。
  非公開 API を使うため、提供元の変更で取得できなくなる可能性がある。
  リセットクレジット消費は `/usage` の明示的な確認操作が必要。
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
