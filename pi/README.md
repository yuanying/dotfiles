# pi/

[pi coding agent](https://github.com/earendil-works/pi) の設定。devbox でも Mac でも
`bin/setup.sh` から呼ばれる `bin/setup-pi.sh` が `~/.pi/agent` へ流し込む。

| 置くもの | 置き場所 | 流し込み方 |
|---|---|---|
| 設定 | `settings.json`、ホスト別は `settings.<hostname>.json` | 手元 < 共通 < ホスト別 の順に jq でマージ。pi が書き戻すので symlink にしない |
| キーバインド | `keybindings.json`、ホスト別は `keybindings.<hostname>.json` | 設定と同じ順でマージ |
| Web 検索 (pi-web-access) | `web-search.json`、ホスト別は `web-search.<hostname>.json` | 同上。pi-web-access も書き戻す |
| auto mode (pi-automode) | `config/pi-automode.json`、ホスト別は `config/pi-automode.<hostname>.json` | `~/.pi/agent/extensions/pi-automode/config.json` へコピーしてマージ。詳細は下記 |
| パッケージ (他人の extension) | `settings.json` の `packages` に `npm:<名前>@<版>` で書く | マージの後に `pi install` で入れる。版は Renovate が追う。詳細は下記 |
| 自作の extension | `extensions/` に単体の `.ts` か、`index.ts` を持つディレクトリ | 1 つずつ symlink |
| テーマ | `themes/<名前>.json` (`name` はファイル名と同じ) | 1 つずつ symlink。どれを使うかは各ホストの `settings` の `theme` |
| プロンプトテンプレート | `prompts/*.md` | 1 つずつ symlink |
| ユーザー指示 | `AGENTS.md` | `~/.pi/agent/AGENTS.md` へ symlink (既存の手書きファイルや他所へのリンクは上書きしない) |

- TUI は `regular` モード。会話を端末のスクロールバックに残し、herdr の
  コピーモードや `prefix+e` で読み返せる。
- 選択リストは矢印キーに加えて `Ctrl+p` / `Ctrl+n` で上下移動する。
  競合する既定キーは、モデルの次 / 前を `Alt+n` / `Alt+p`、
  `/resume` のパス表示 / 名前付きフィルタを `Alt+p` / `Alt+n`、
  `/scoped-models` のプロバイダー一括切替を `Alt+p` に変更している。
- 入力欄の履歴は `Ctrl+p` / `Ctrl+n` で前 / 次へ移動する。
  `Ctrl+[` も選択画面のキャンセルと生成中の中断に使える (`Esc` はそのまま)。
- 利用率表示は `@specode/pi-subscription-usage`。フッターの `1w` が週間使用率。
  `subscription-usage.json` の `displayMode: "used"` で消費した割合を表示する。
  設定は他の JSON と同じ順でマージし、`/usage` で詳細表示・再取得する。
  `openai` の ChatGPT サブスクリプションでは、同じアカウント・ワークスペースで
  `/login openai-codex` も一度行う。Codex 認証は Usage の取得だけに使い、
  モデルは `openai` のままでよい。プラン全体とアプリ別の制限は別々に表示する。
  非公開 API のため提供元の変更で取得できなくなる可能性がある。
  リセットクレジット消費は `/usage` の明示的な確認操作が必要。
- `claude-bridge` / `anthropic` の利用率は上のパッケージが対応していないので、
  自作の `extensions/claude-usage.ts` がフッターに `5h` / `1w` を同じ書式で出す。
  `displayMode` も `subscription-usage.json` に揃える。認証は `/login anthropic`
  だけを使い、Claude Code の `/usage` と同じ非公開 API を読む。
  `/claude-usage` で再取得し、Opus / Sonnet の週間枠も表示する。
- pi 本体にはコマンドをバックグラウンドで走らせる機能が無いので、自作の
  `extensions/background-bash.ts` が `bg_run` / `bg_list` / `bg_kill` ツールを足す。
  `bg_run` はすぐに戻り、コマンドが終了すると exit code と出力の末尾を会話へ
  差し込んでターンを始める (処理中なら今の処理の後)。`herdr-tasks` の coordinator が
  `herdr agent wait` を置いて worker の完了を待つのに使う。全文のログは
  `$TMPDIR/pi-background-bash-*/` に残る。ジョブはセッションの終了や `/reload` で
  止まり、結果は届かない。`bg_run` の呼び出しも pi-automode の判定を通る。
- スキルはここに置かない。pi は `~/.agents/skills` も読むので、リポジトリ直下の
  `skills/` が `bin/setup-skills.sh` 経由で届く。
- pi 専用の `AGENTS.md` でユーザー指示を管理する。`herdr-tasks` 使用時は、
  特に指示がなければ worker を `claude` で起動する。
  以前の setup が張った `~/.claude/CLAUDE.md` へのリンクは削除するが、
  手書きの `CLAUDE.md` や他所へのリンクは残す。
- `PI_CODING_AGENT_DIR` があれば設定・リンク先を変更する。ただし pi-automode は
  現在この変数を参照しないため、その設定だけは固定の `~/.pi/agent` 配下へ置く。
- マージは配列を丸ごと置き換えるので、手元で `pi install` しただけのパッケージ宣言は
  次の setup で消える。ホスト固有のパッケージは `settings.<hostname>.json` の
  `packages` に共通の分も含めて全部書く (Renovate はこちらの版も追う)。
  setup が `pi install` するのは共通の `settings.json` の分だけなので、
  ホスト固有のものは初回だけ手で `pi install` する。
- `extensions/` を丸ごと symlink にしないのは、`herdr integration install pi` と
  `moshi-hook install` が同じディレクトリに自分のファイルを置くため。
- `auth.json` とセッションはホストごとのまま。ログインは各ホストで `/login` を 1 回。
- 本体の版は `devbox/Dockerfile` の `ARG PI_VERSION`。Mac では
  `bin/mac/setup-packages.sh` がそれを読んで同じ版を npm で入れる。

## auto mode

`@czottmann/pi-automode` を使う。読み取りツールは原則モデル判定なし、書き込みと
シェル操作は標準ポリシーによる判定に任せる。`allowInsideWorkingDirectory` は
`false` のままにし、作業ディレクトリ内の編集も判定を省略しない。
分類器のモデルは `classifierModel` で `openai-codex/gpt-6-luna` に固定する。
各ホストで `/login openai-codex` が必要。`/automode model` で選び直した値は、
次の setup でリポジトリの値に上書きされる。
`/automode status`、`/automode config`、`/automode denials` で状態を確認する。

`permissions.allow` で分類器を通さずに許可するのは次のもの。

- `web_enable`。設定済み Web ツールの有効化だけで、検索・取得は通常の判定に残す。
- herdr-tasks のタスクディレクトリ (`~/.local/state/herdr-tasks/`) 配下への
  `write` / `edit`。coordinator が `TASK.md` / `STATE.md` / `PROGRESS.md` / `notes/` を
  書くたびに止まらないようにする。パターンの `*` は `/` をまたぐので、
  配下の `worktrees/` (worker のリポジトリ) も含む。protected paths
  (`.git` や `.pi` など) への書き込みは、この許可があっても分類器に回る。
- herdr の操作。`workspace` / `tab` / `agent` / `worktree` / `notification` は
  close を含めてすべて、`pane` は参照・レイアウト操作・`close`・`wait-output`。
  `agent start` / `prompt` は別 agent へ作業を委譲する権限も含む。
  `pane run` / `send-text` / `send-keys` / `input` は別の pane のシェルに任意の
  コマンドを打ち込めるので、herdr 自体の管理 (`server` / `update` / `config` など) と
  一緒に分類器に残す。
- worktree ラッパー `~/bin/herdr-task-worktree` と、herdr-tasks スキルの
  `scripts/prompt-agent.sh` / `scripts/write-task-agents.sh`。

Bash のパターンは文字どおりに照合され (`~` も `$HOME` も展開されない)、ホームは
ホストごとに違う。そのためスクリプトの絶対パスは `__HOME__` で書き、setup がコピーする
ときに置き換える。変数展開・コマンド置換・リダイレクトを含むものや、許可していない
コマンドを `;` や `|` でつないだものは、パターンに合っても分類器に回る。
引数は展開済みの値を単独コマンドで渡し、拒否された操作を別表記や複合コマンドで
回避しない。

分類器の `autoMode.allow` には、組み込み (`$defaults`) に加えて
「git 管理下の既存ファイルの編集・上書きは、都度の許可なしに許す」例外を置く。
組み込みの既定では、既存ファイルの変更にタスク・リポジトリ・パス・操作を
名指しした許可を求めるので、実装のたびに止まる。git が復元できる範囲だけを
緩め、削除、未追跡・無視対象のファイル、protected paths は対象にしない。
分類器はツールの結果を見ないため追跡の有無を確かめられず、パスから推し量る。
自然言語のルールなので、効くかどうかも分類器の判断次第である。
auto mode の設定そのものの編集は組み込みの hard_deny に当たるため、この例外が
あってもブロックされる。

ポリシーのマージ順は手元 < 共通 < ホスト別。`permissions.allow` と `autoMode.allow` は管理値で置換する。
`permissions.deny` / `permissions.ask` / `autoMode.deniedPaths` と、
`soft_deny` / `hard_deny` / `protectedPaths` は和集合にして手元の制限も残す。
組み込みの禁止・保護ルールは `$defaults` を保持する。分類器のモデルやログ設定は、
共通・ホスト別で指定しない限り手元の値を残す。設定は symlink にしない。

### pi-verdict からの移行

**pi を終了し、pi 外のシェルで反映する。agent から setup を実行しない。**

```bash
~/dotfiles/bin/setup-pi.sh
```

setup はパッケージ宣言を pi-automode に切り替えてインストールする。旧パッケージの
インストール済みファイルは残っても、宣言がないためロードされない。
旧 `~/.pi/agent/config/pi-verdict.json` は変更・削除しない。
その `denyPaths` はパス本体と配下を表す glob に変換して引き継ぐ。
旧設定では確認だった対象が、新しい `deniedPaths` では **file tools の拒否**になる。
このリストは bash を対象とせず、シェルは組み込み検査と分類器で判定する。

旧 `deny` の正規表現は自動変換できない。初回移行時に非空なら、パッケージ設定を
変更する前に setup を停止する。手動で制限を新設定の `permissions.deny` または
`autoMode.hard_deny` に移して新設定ファイルを作成してから再実行する。
旧 `allow` / `ignoreTools` / 分類器・監査設定は自動移行しない。
`config/pi-verdict.json` と `test/pi-herdr-rules.mjs` は旧形式の参照用で、setup は使わない。

再起動して `/automode status` で pi-automode が有効なことを確認する。

## herdr worktree

worktree は `bin/setup-pi.sh` が `~/bin` にリンクするラッパーを使う。

```bash
~/bin/herdr-task-worktree --repo /absolute/repo \
  --path /absolute/home/.local/state/herdr-tasks/task/worktrees/branch \
  --branch feature-branch --base <base-sha>
```

作成先は `~/.local/state/herdr-tasks/<task>/worktrees/` 下に限定し、
パストラバーサル・外へ向かう symlink・既存の作成先を拒否する。新規ブランチの
作成だけを行い、tab は別途 `herdr tab create` で作る。OS サンドボックスではない。

自作の extension を足したら各ホストで `bin/setup-pi.sh` を流す (devbox は起動時)。
既に張ってあるものの変更だけなら pi で `/reload` する。
