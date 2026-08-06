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
  })
end

return M