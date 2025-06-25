-- return {
  -- "yuanying/tender.vim",
  -- branch = 'dev',
  -- lazy = false,
  -- priority = 1000,
  -- config = function()
  --   vim.cmd([[colorscheme tender]])
  -- end,
-- }
return {
  {
    -- 'mhartington/oceanic-next',
        -- colorscheme OceanicNext
    'glepnir/zephyr-nvim',
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function ()
      vim.cmd([[
        colorscheme zephyr
      ]])
      local configs = require("nvim-treesitter.configs")

      configs.setup({
          ensure_installed = { "c", "lua", "vim", "vimdoc", "json", "go", "ruby", "python", "yaml", "javascript", "html" },
          sync_install = false,
          highlight = { enable = true },
          indent = { enable = true },
        })
    end
  }
}