-- Ghostty の Hopscotch.256 と同じ Base16 Hopscotch パレット。
-- mini.base16 で Neovim の UI と構文色に適用する。
local palette = {
  base00 = "#322931", -- 背景
  base01 = "#433b42", -- 行番号の背景、ステータスライン
  base02 = "#5c545b", -- 選択範囲
  base03 = "#797379", -- コメント
  base04 = "#989498", -- 暗めの文字
  base05 = "#b9b5b8", -- 文字
  base06 = "#d5d3d5",
  base07 = "#ffffff",
  base08 = "#dd464c", -- 変数、エラー
  base09 = "#fd8b19", -- 数値、定数
  base0A = "#fdcc59", -- 型、検索
  base0B = "#8fc13e", -- 文字列
  base0C = "#149b93", -- 正規表現、エスケープ
  base0D = "#1290bf", -- 関数
  base0E = "#c85e7c", -- キーワード
  base0F = "#b33508", -- 区切り、非推奨
}

vim.o.background = "dark"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "hopscotch256"
