-- Crayon Pony Fish (Ghostty の組み込みテーマ) の配色。aemilia で herdr /
-- Claude Code / Codex / pi と揃えるために使う。
--
-- Crayon Pony Fish の nvim 版は無いので、パレットを mini.base16 に渡して作る。
-- 赤黒い背景に灰色がかった桃色の文字。Ghostty の前景色 (#68525a) は文字には
-- 暗すぎるので、パレットの明るい白 (#b0949d) を文字に使う。関数は薄紫、
-- 文字列はライム、キーワードはピンクで、pi / Codex のテーマと揃えてある。
local palette = {
  base00 = "#150707", -- 背景
  base01 = "#2b1b1d", -- 行番号の背景、ステータスライン
  base02 = "#4a383b", -- 選択範囲
  base03 = "#8c737c", -- コメント
  base04 = "#8c737c", -- 暗めの文字
  base05 = "#b0949d", -- 文字
  base06 = "#ffceaf",
  base07 = "#ffceaf",
  base08 = "#c5255d", -- 変数、エラー
  base09 = "#e8a866", -- 数値、定数
  base0A = "#ffceaf", -- 型、検索
  base0B = "#8dff57", -- 文字列
  base0C = "#8c87b0", -- 正規表現、エスケープ
  base0D = "#cfc9ff", -- 関数
  base0E = "#fc6cba", -- キーワード
  base0F = "#c8381d", -- 区切り、非推奨
}

vim.o.background = "dark"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "crayonponyfish"
