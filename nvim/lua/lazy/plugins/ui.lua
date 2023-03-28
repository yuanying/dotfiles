return {
  -- {
  --   "nvim-lualine/lualine.nvim",
  --   lazy = false,
  --   dependencies = {
  --   },
  --   config = function()
  --     require('lualine').setup()
  --   end,
  -- },
  {
    "vim-airline/vim-airline",
    dependencies = {
      "vim-airline/vim-airline-themes",
    },
    config = function()
      vim.cmd([[
      let g:airline_powerline_fonts = 1
      if !exists('g:airline_symbols')
        let g:airline_symbols = {}
      endif
      " unicode symbols
      let g:airline_left_sep = ''
      let g:airline_right_sep = ''
      let g:airline_symbols.colnr = ' ㏇:'
      let g:airline_symbols.colnr = ' ℅:'
      let g:airline_symbols.crypt = '🔒'
      let g:airline_symbols.linenr = '☰'
      let g:airline_symbols.linenr = ' ␊:'
      let g:airline_symbols.linenr = ' ␤:'
      let g:airline_symbols.linenr = '¶'
      let g:airline_symbols.maxlinenr = ''
      let g:airline_symbols.maxlinenr = '㏑'
      let g:airline_symbols.branch = '⎇'
      let g:airline_symbols.paste = 'ρ'
      let g:airline_symbols.paste = 'Þ'
      let g:airline_symbols.paste = '∥'
      let g:airline_symbols.spell = 'Ꞩ'
      let g:airline_symbols.notexists = 'Ɇ'
      let g:airline_symbols.notexists = '∄'
      let g:airline_symbols.whitespace = 'Ξ'

      if $AIRLINE_THEME == ""
        let g:airline_theme = 'tender'
      else
        let g:airline_theme = $AIRLINE_THEME
      endif
      ]])
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