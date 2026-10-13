-- Lab Fox (Ghostty の組み込みテーマ) の配色。aemilia で herdr /
-- Claude Code / Codex / pi と揃えるために使う。
--
-- Lab Fox の nvim 版は無いので、パレットを mini.base16 に渡して作る。
-- Lab Fox には青と水色が無く、紫 (#6e49cb) は暗い背景で読みにくいため、
-- 関数などの青の役割には明るくした紫を当てる。キーワードはオレンジで、
-- pi / Codex のテーマと揃えてある。
local palette = {
  base00 = "#2e2e2e", -- 背景
  base01 = "#3a3a3a", -- 行番号の背景、ステータスライン
  base02 = "#535353", -- 選択範囲
  base03 = "#7f7f7f", -- コメント
  base04 = "#b2b2b2", -- 暗めの文字
  base05 = "#ffffff", -- 文字
  base06 = "#ffffff",
  base07 = "#ffffff",
  base08 = "#ec5941", -- 変数、エラー
  base09 = "#fca121", -- 数値、定数
  base0A = "#fdc06e", -- 型、検索
  base0B = "#3eb383", -- 文字列
  base0C = "#53eaa8", -- 正規表現、エスケープ
  base0D = "#9e7cf0", -- 関数
  base0E = "#fc6d26", -- キーワード
  base0F = "#e57ab8", -- 区切り、非推奨
}

vim.o.background = "dark"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "labfox"
