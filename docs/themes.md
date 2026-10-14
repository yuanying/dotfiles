# ホスト別テーマの追加と変更

テーマ名とホストの対応は [`themes/host.zsh`](../themes/host.zsh) で管理する。zsh はこのファイルを Spaceship より先に読み込み、`DOTFILES_THEME`、Neovim、vim-airline、Claude Code の statusline のテーマを決める。Spaceship は `DOTFILES_THEME` に対応する [`themes/spaceship/`](../themes/spaceship/) のパレットを読み込む。未登録ホストは Solarized にする。

herdr、Codex、pi、Claude Code はそれぞれ設定形式とテーマ名が異なるため、テーマの選択にはホスト別設定ファイルを使う。`DOTFILES_THEME` の名前からこれらの設定を自動生成しない。

## 既存テーマを別ホストで使う

1. `themes/host.zsh` にホストを追加し、`DOTFILES_THEME` と `AIRLINE_THEME` を指定する。Neovim と Claude Code の statusline は `DOTFILES_THEME` を引き継ぐ。
2. `herdr/config.<hostname>.toml` の `[theme]`、`codex/config.<hostname>.toml` の `theme`、`pi/settings.<hostname>.json` と `claude/settings.<hostname>.json` の `theme` を設定する。既存の同テーマのホスト別ファイルを参考にする。herdr の設定は全体を 1 ファイルで持つため、共通設定も複製する。
3. `bin/setup.sh` を実行する。既存シェルと各アプリを起動し直して反映を確認する。

## 新しいテーマを追加する

1. `themes/host.zsh` にテーマ名と、必要なら対応する vim-airline のテーマ名を追加する。
2. `themes/spaceship/<theme>.zsh` を作り、既存ファイルと同じ 7 色 (`accent`、`secondary`、`info`、`muted`、`success`、`warning`、`error`) を定義する。Spaceship の各セクションへの割り当ては `spaceshiprc.zsh` にまとめてある。
3. 各アプリのテーマを用意する。herdr は `herdr/config.<hostname>.toml`、Codex は `codex/config.<hostname>.toml` と必要なら `codex/themes/`、pi は `pi/settings.<hostname>.json` と `pi/themes/`、Claude Code は `claude/settings.<hostname>.json` と必要なら `claude/themes/` を更新する。
4. `claude/statusline-command.sh` に同じパレットを追加する。Neovim にテーマがなければ `nvim/colors/` または `nvim/lua/lazy/plugins/colorscheme.lua` に登録する。Ghostty の端末全体の配色も合わせる場合は `ghostty/config` を更新する。
5. `bin/setup.sh` を実行し、新しいシェルでプロンプトと Neovim、各アプリのテーマを確認する。

テーマ名がアプリで異なる例: `DOTFILES_THEME=labfox`、Codex は `lab-fox`、Claude Code は `custom:labfox`。この対応は各アプリの設定ファイルで明示する。
