---
name: web-design-guidelines
description: >-
  Vercel の Web Interface Guidelines に照らして Web UI のコードをレビューする。
  「UI をレビューして」「アクセシビリティを確かめて」など、Web UI の操作性、
  アクセシビリティ、表示や動作の問題を確認する依頼に使う。
---

# Web UI をレビューする

1. 毎回、この `SKILL.md` の実体があるディレクトリを起点に [`references/command.md`](references/command.md) を読む。規則をネットから取得しない。
2. 規則内の `$ARGUMENTS` は、ユーザーが指定したファイルやパターンとして扱う。指定がなく、依頼内容からも対象が分からなければ確認する。対象のコードと、適用されるプロジェクトのデザイン方針を読む。
3. コードを規則に照らして確認する。プロジェクトのデザイン方針や意図した例外は規則より優先し、食い違いを報告するときは「プロジェクトの決まりと食い違う」と添え、規則違反ではなく方針上の例外として示す。
4. 指摘はファイルごとにまとめ、`file:line - 問題と修正案` の形で簡潔に書く。指摘がなければその旨を示す。実際の操作でしか確認できない項目は、コードから確認できたことと区別する。

## 規則の出典

- 上流: <https://github.com/vercel-labs/web-interface-guidelines>
- 固定コミット: `434b7f91364665f2f733b310ec54809bf8f37937`
- `references/command.md` のライセンス: [MIT](references/LICENSE)
- SHA-256: `d246b026f4f29b5823a9cc857f9edf3d2507002e055e32040cadeaf3b38e0234`

## 規則の更新

1. 上流から新しいコミットを選び、そのコミットの `command.md` と `LICENSE` を取得する。
2. `references/` にある現行版との差分を読み、規則・出力形式・ライセンスの変更を確認してから、両ファイルを改変せずに `references/` に写す。
3. スキルのディレクトリで `shasum -a 256 references/command.md`でハッシュを計算し、固定コミットと SHA-256 を更新する。リポジトリルートで `bats test/web-design-guidelines.bats` を実行する。

Renovate の regex マネージャーでコミットを追跡することはできるが、固定値の置換だけでは規則やライセンスが更新されない。差分を確認してから、固定値と同梱ファイルを同じ PR で手動更新する。
