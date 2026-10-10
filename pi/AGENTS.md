# ユーザー指示

- `herdr-tasks` スキルを使用している際は、特に指示がない場合、worker を `claude` で起動すること。
- `herdr-tasks` の worktree 作成には `git worktree add` の代わりに
  `~/bin/herdr-task-worktree --repo <repo> --path <task-dir>/worktrees/<branch> --branch <branch> --base <base-sha>`
  を使う。tab はスキルの手順どおり別途作成する。
- herdr の許可対象操作は、シェル変数を展開済みの単独コマンドで実行する。
  複合コマンドや変数展開は自動許可ルールに含めない。自動許可のために
  指示の意味や安全確認を変えたり、拒否された操作を別表記で回避したりしない。
