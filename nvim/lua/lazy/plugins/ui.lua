return {
  {
    "nvim-lualine/lualine.nvim",
    lazy = false,
    dependencies = {
    },
    config = function()
      require('lualine').setup()
    end,
  },
  {
    "edkolev/tmuxline.vim",
    config = function()
      vim.g.tmuxline_theme = 'zenburn'
    end,
  },
  -- {
  --   "vimpostor/vim-tpipeline",
  -- },
  {
    "lambdalisue/fern.vim",
    dependencies = {
      "lambdalisue/fern-mapping-project-top.vim",
      "lambdalisue/fern-renderer-nerdfont.vim",
      "lambdalisue/nerdfont.vim",
    },
    config = function()
      vim.keymap.set('n', '<C-e>', ':Fern . -reveal=%<CR>')
      vim.g['fern#renderer'] = "nerdfont"
      vim.api.nvim_create_augroup('fern-custom', {})
      vim.api.nvim_create_autocmd("FileType", {
        group = 'fern-custom',
        pattern = 'fern',
        callback = function()
          vim.api.nvim_buf_set_keymap(0, 'n', '<Enter>', '<Plug>(fern-action-open-or-expand)', {})
          vim.api.nvim_buf_set_keymap(0, 'n', 'l', '<Plug>(fern-action-open)', {})
        end
      })
    end,
  },
  {
    'gen740/SmoothCursor.nvim',
    config = function()
      require('smoothcursor').setup()
    end,
  },
}