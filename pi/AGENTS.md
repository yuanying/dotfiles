# ユーザー指示

- `herdr-tasks` スキルを使用している際は、特に指示がない場合、coodinatorは`pi`、worker を `claude` で起動すること。
- `herdr-tasks` の worktree 作成には `git worktree add` の代わりに
  `~/bin/herdr-task-worktree --repo <repo> --path <task-dir>/worktrees/<branch> --branch <branch> --base <base-sha>`
  を使う。tab はスキルの手順どおり別途作成する。
- その worktree を消すときは `git worktree remove` の代わりに
  `~/bin/herdr-task-worktree remove --path <task-dir>/worktrees/<branch>` を使う。
  マージ済みのブランチも消すなら `--delete-branch` を付ける。未コミットの変更や
  未追跡のファイルがあると拒否されるので、その場合は消してよいかユーザーに確認する。
- worktree を作る前などに元リポジトリを fetch するときは、`git -C <repo> fetch` の代わりに
  `~/bin/herdr-task-worktree fetch --repo <repo>` を使う (origin を fetch する)。
  サンドボックスが有効だと、起動ディレクトリの外のリポジトリには書き込めないため。
- herdr の許可対象操作は、シェル変数を展開済みの単独コマンドで実行する。
  複合コマンドや変数展開は自動許可ルールに含めない。自動許可のために
  指示の意味や安全確認を変えたり、拒否された操作を別表記で回避したりしない。
