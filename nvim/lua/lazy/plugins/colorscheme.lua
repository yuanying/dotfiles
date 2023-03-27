return {
  "yuanying/tender.vim",
  branch = 'dev',
  lazy = false,
  priority = 1000,
  config = function()
    vim.cmd([[colorscheme tender]])
  end,
}