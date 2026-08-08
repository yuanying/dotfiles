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
    -- setup() は colorscheme コマンドより先に呼ぶ必要がある。
    -- 他のプラグインより先に読み込ませるため lazy = false / priority = 1000。
    "ellisonleao/gruvbox.nvim",
    lazy = false,
    priority = 1000,
    opts = {},
    config = function(_, opts)
      require("gruvbox").setup(opts)
      vim.o.background = "dark"
      vim.cmd([[colorscheme gruvbox]])
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    config = function ()
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