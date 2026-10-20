-- VS Code の Atom One Light を mini.base16 のパレットに移す。
local palette = {
  base00 = "#fafafa", -- editor background
  base01 = "#eaeaeb", -- sidebar and status line
  base02 = "#e5e5e6", -- selection
  base03 = "#a0a1a7", -- comments
  base04 = "#696c77", -- muted text
  base05 = "#383a42", -- editor foreground
  base06 = "#232324",
  base07 = "#121417",
  base08 = "#e45649", -- variables
  base09 = "#986801", -- numbers
  base0A = "#c18401", -- types
  base0B = "#50a14f", -- strings
  base0C = "#0184bc", -- regex
  base0D = "#4078f2", -- functions
  base0E = "#a626a4", -- keywords
  base0F = "#ca1243",
}

vim.o.background = "light"
require("mini.base16").setup({ palette = palette })
vim.g.colors_name = "atomonelight"
