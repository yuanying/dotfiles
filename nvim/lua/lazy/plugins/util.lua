return {
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  -- {
  --   "mattn/vim-goimports",
  --   config = function()
  -- 
  --   end,
  -- },
  {
    'tyru/caw.vim',
    config = function()
      vim.keymap.set('n', '<C-\\>', '<Plug>(caw:hatpos:toggle)')
      vim.keymap.set('v', '<C-\\>', '<Plug>(caw:hatpos:toggle)')
    end,
  },
  {
    "romgrk/barbar.nvim",
    dependencies = {
      "nvim-web-devicons",
    },
    lazy = false,
    config = function()
      vim.keymap.set('n', '<C-n>', '<Cmd>BufferNext<CR>')
      vim.keymap.set('n', '<C-p>', '<Cmd>BufferPrevious<CR>')
      vim.keymap.set('n', '<C-x>', '<Cmd>BufferClose<CR>')
    end,
  },
  {
    'nvim-telescope/telescope.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'BurntSushi/ripgrep',
      'kelly-lin/telescope-ag',
      "nvim-web-devicons",
    },
    config = function()
      local builtin = require('telescope.builtin')
      local ag = require('telescope._extensions.ag')
      vim.keymap.set('n', '<leader>t', builtin.find_files, {})
      vim.keymap.set('n', '<leader>a', ':Ag<Space>', {})
      vim.keymap.set('n', '<leader>b', builtin.buffers, {})
      vim.keymap.set('n', '<leader>r', builtin.registers, {})
    end,
  }
}
