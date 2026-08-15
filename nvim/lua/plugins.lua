local M = {}

function M.setup()
  local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
  if not vim.loop.fs_stat(lazypath) then
    vim.fn.system({
      "git",
      "clone",
      "--filter=blob:none",
      "https://github.com/folke/lazy.nvim.git",
      "--branch=stable",
      lazypath,
    })
  end

  vim.opt.rtp:prepend(lazypath)
  local plugins = {
    {
      "folke/lazy.nvim",
      lazy = false,
      version = "*",
    },
    {
      import = "lazy.plugins"
    },
  }
  local lazy = require("lazy")
  lazy.setup({
    spec = plugins,
    change_detection = {
      enabled = true,
      notify = false,
    },
    install = {
      missing = true,
      colorscheme = {'default'},
    },
    performance = {
      rtp = {
        -- lazy は既定で runtimepath を「設定ディレクトリ + $VIMRUNTIME + lazy が
        -- 管理するプラグイン」へ切り詰める。nvim 同梱の tree-sitter parser は
        -- $VIMRUNTIME ではなく <prefix>/lib/nvim/parser に置かれているため、
        -- これが落ちると markdown を開くたびに標準の ftplugin が parser を
        -- 作れず E5113 で落ちる (nvim-treesitter は markdown を入れていない)。
        -- パスを自前で足すとインストール形態ごとに変わるので、nvim が決めた
        -- 既定の runtimepath をそのまま使う。
        reset = false,
      },
    },
  })
end

return M