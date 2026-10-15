-- Matte Black (Ghostty の組み込みテーマ) の配色。augusta で herdr /
-- Claude Code / Codex / pi と揃えるために使う。
--
-- Matte Black の nvim 版は無いので、パレットを mini.base16 に渡して作る。
-- 灰色が主で、色はアンバー、オレンジ、赤しか無い。関数はオレンジ、文字列は
-- アンバー、キーワードは赤で、pi / Codex のテーマと揃えてある。
local palette = {
  base00 = "#121212", -- 背景
  base01 = "#1c1c1c", -- 行番号の背景、ステータスライン
  base02 = "#333333", -- 選択範囲
  base03 = "#8a8a8d", -- コメント
  base04 = "#8a8a8d", -- 暗めの文字
  base05 = "#bebebe", -- 文字
  base06 = "#eaeaea",
  base07 = "#ffffff",
  base08 = "#d35f5f", -- 変数、エラー
  base09 = "#f59e0b", -- 数値、定数
  base0A = "#eaeaea", -- 型、検索
  base0B = "#ffc107", -- 文字列
  base0C = "#bebebe", -- 正規表現、エスケープ
  base0D = "#e68e0d", -- 関数
  base0E = "#d35f5f", -- キーワード
  base0F = "#b91c1c", -- 区切り、非推奨
}

vim.o.background = "dark"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "matteblack"
