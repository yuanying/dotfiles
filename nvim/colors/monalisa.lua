-- Mona Lisa (Ghostty の組み込みテーマ) の配色。augusta で herdr /
-- Claude Code / Codex / pi と揃えるために使う。
--
-- Mona Lisa の nvim 版は無いので、パレットを mini.base16 に渡して作る。
-- 暗い茶色の背景に黄色の文字。関数は青灰色、文字列はオリーブ、キーワードは
-- ピンクがかった赤で、pi / Codex のテーマと揃えてある。
local palette = {
  base00 = "#120b0d", -- 背景
  base01 = "#24130e", -- 行番号の背景、ステータスライン
  base02 = "#522917", -- 選択範囲
  base03 = "#a78f49", -- コメント
  base04 = "#a78f49", -- 暗めの文字
  base05 = "#f7d66a", -- 文字
  base06 = "#ffe598",
  base07 = "#ffe598",
  base08 = "#ff4331", -- 変数、エラー
  base09 = "#ff9566", -- 数値、定数
  base0A = "#8acd8f", -- 型、検索
  base0B = "#b4b264", -- 文字列
  base0C = "#c46c32", -- 正規表現、エスケープ
  base0D = "#9eb2b4", -- 関数
  base0E = "#ff5b6a", -- キーワード
  base0F = "#874228", -- 区切り、非推奨
}

vim.o.background = "dark"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "monalisa"
