# pi/

[pi coding agent](https://github.com/earendil-works/pi) の設定。devbox でも Mac でも
`bin/setup.sh` から呼ばれる `bin/setup-pi.sh` が `~/.pi/agent` へ流し込む。

| 置くもの | 置き場所 | 流し込み方 |
|---|---|---|
| 設定 | `settings.json`、ホスト別は `settings.<hostname>.json` | 手元 < 共通 < ホスト別 の順に jq でマージ。pi が書き戻すので symlink にしない |
| キーバインド | `keybindings.json`、ホスト別は `keybindings.<hostname>.json` | 設定と同じ順でマージ |
| Web 検索 (pi-web-access) | `web-search.json`、ホスト別は `web-search.<hostname>.json` | 同上。pi-web-access も書き戻す |
| auto mode の許可ポリシー (pi-verdict) | `config/pi-verdict.json`、ホスト別は `config/pi-verdict.<hostname>.json` | コピーしてマージ。`allow` は管理値で置換、`deny` / `denyPaths` は手元・共通・ホスト別の和集合 |
| パッケージ (他人の extension) | `settings.json` の `packages` に `npm:<名前>@<版>` で書く | マージの後に `pi install` で入れる。版は Renovate が追う |
| 自作の extension | `extensions/` に単体の `.ts` か、`index.ts` を持つディレクトリ | 1 つずつ symlink |
| テーマ | `themes/<名前>.json` (`name` はファイル名と同じ) | 1 つずつ symlink。どれを使うかは各ホストの `settings` の `theme` |
| プロンプトテンプレート | `prompts/*.md` | 1 つずつ symlink |
| ユーザー指示 | `AGENTS.md` | `~/.pi/agent/AGENTS.md` へ symlink (既存の手書きファイルや他所へのリンクは上書きしない) |

- TUI は `regular` モードを使う。会話を端末のスクロールバックに残し、
  herdr のコピーモードや `prefix+e` で読み返せるようにする。
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
- ユーザー指示は pi 専用の `AGENTS.md` で管理する。`herdr-tasks` 使用時は、
  特に指示がなければ worker を `claude` で起動する。
  以前の setup が張った `~/.claude/CLAUDE.md` へのリンクは削除するが、
  手書きの `CLAUDE.md` や他所へのリンクは残す。
  `PI_CODING_AGENT_DIR` があれば、そのディレクトリをリンク先に使う。
- `extensions/` を丸ごと symlink にしないのは、`herdr integration install pi` と
  `moshi-hook install` が同じディレクトリに自分のファイルを置くため。
- `auth.json` とセッションはホストごとのまま。ログインは各ホストで `/login` を 1 回。
- 本体の版は `devbox/Dockerfile` の `ARG PI_VERSION`。Mac では
  `bin/mac/setup-packages.sh` がそれを読んで同じ版を npm で入れる。

## herdr と auto mode

`web_enable` は `ignoreTools` で自動許可する。これは設定済みの Web ツールを
有効にする操作だけで、検索・ページ取得はそれぞれ通常の判定に残る。
setup は `ignoreTools` を手元・共通・ホスト別の和集合にし、既存の免除を保持する。

`pi-verdict` の `allow` で herdr の一覧・参照、workspace/tab の作成・移動、
agent の起動・プロンプト送信などを分類器を通さず許可する。起動・送信は
別 agent に作業を委譲する権限も含む。後片付け用の `herdr tab close <tab-id>` も、
`w14:t2` のような明示的な tab ID を1つ指定した単独コマンドに限り許可する。
これは指定した tab のセッションを終了する権限を含み、完了済みかどうかは
ルールでは判定しない。workspace の close や許可対象外の削除、`pane run` / `send-text`、
更新、直接の `herdr worktree create/remove` はこの許可に含めない。
許可されない操作は通常の判定に戻るため、確認ではなく拒否される場合もある。

`herdr-tasks/scripts/` の直下にある `.sh` は、そのスクリプトへの信頼を前提に
自動許可する。対象は `$HOME/src/github.com/yuanying/herdr-tasks` と
`$HOME/.agents/skills/herdr-tasks`、`$HOME/.claude/skills/herdr-tasks` の3か所。
引用符内のプロンプトは改行や日本語を含められるが、変数展開・コマンド置換・
バックスラッシュは許可しない。これは agent への push・PR作成などの委譲や、
インストール用スクリプトの実行も含む。ディレクトリ内のスクリプトが変更された
場合も自動許可は続くため、信頼できるチェックアウト・リンクだけを置く。

herdr CLI と worktree のルールはコマンド全体に一致させる。複合コマンド、改行、リダイレクト、
変数展開・コマンド置換・バックスラッシュを含むものは通常の判定に戻す。
引数は値を展開して単独のコマンドで渡す。保護パスや組み込みの危険操作判定は
許可ルールより優先し、auto mode 全体は無効にしない。

worktree は次のラッパーを使う (`bin/setup-pi.sh` が `~/bin` にリンクする)。
許可ルールの `__HOME_REGEX__` は setup 時に、その環境の `$HOME` を正規表現用に
エスケープした値へ置換する。`~/bin/herdr-task-worktree` に加えて展開済みの
絶対パスも許可するが、別ユーザーのホーム配下には許可を広げない。

```bash
~/bin/herdr-task-worktree --repo /absolute/repo \
  --path /absolute/home/.local/state/herdr-tasks/task/worktrees/branch \
  --branch feature-branch --base <base-sha>
```

後片付けの `git -C /absolute/repo worktree remove <path>` は、削除先が展開済みの
`$HOME/.local/state/herdr-tasks/<task>/worktrees/<branch>` と一致する場合だけ許可する。
`task` は英数字・`_`・`#`・`-`、`branch` は英数字・`_`・`-` の単一要素に限定し、
削除先の引用符は使用できる。`--force`、追加引数、`..`、範囲外の削除は許可しない。
未コミット変更の保護は Git の通常の判定に任せる。このルールは文字列の範囲を
制限するもので、削除先の祖先 symlink の実体までは検証しない。

作成先は `~/.local/state/herdr-tasks/<task>/worktrees/` の下に限定し、
パストラバーサル・外へ向かう symlink・既存の作成先を拒否する。新規ブランチの
作成だけを行い、tab 作成は別途 `herdr tab create` で行う。ラッパーやポリシーは
OS サンドボックスではない。並行した symlink の差し替えなど、同じユーザーの
悪意あるプロセスまで隔離するものではない。

**許可設定の反映は pi を終了し、pi 外のシェルで `bin/setup-pi.sh` を実行してから
再起動する。** pi-verdict は自身の設定変更を保護しているため、この操作を
agent に実行させない。手元の `deny` / `denyPaths` や分類器の設定は残るが、
`allow` は dotfiles の管理値に置き換わる。追加ルールは共通またはホスト別に書く。

自作の extension を足したら、各ホストで `bin/setup-pi.sh` を流すか (devbox は
起動時に流れる)、既に張ってあるものを直しただけなら pi で `/reload` する。
