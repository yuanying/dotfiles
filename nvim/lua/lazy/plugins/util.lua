return {
  {
    "nvim-tree/nvim-web-devicons",
    lazy = true,
  },
  {
    "github/copilot.vim",
      config = function()
      -- vim.g.copilot_no_tab_map = true

      local keymap = vim.keymap.set
      -- https://github.com/orgs/community/discussions/29817#discussioncomment-4217615
      -- keymap(
      --   "i",
      --   "<C-g>",
      --   'copilot#Accept("<CR>")',
      --   { silent = true, expr = true, script = true, replace_keycodes = false }
      -- )
      keymap("i", "<C-j>", "<Plug>(copilot-next)")
      keymap("i", "<C-k>", "<Plug>(copilot-previous)")
      keymap("i", "<C-o>", "<Plug>(copilot-dismiss)")
      keymap("i", "<C-s>", "<Plug>(copilot-suggest)")
    end,
  },
  {
    "mattn/vim-goimports",
    config = function()
      vim.g.goimports = 1
    end,
  },
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
      "nvim-web-devicons",
      'nvim-treesitter/nvim-treesitter',
    },
    config = function()
      local builtin = require('telescope.builtin')
      vim.keymap.set('n', '<leader>t', builtin.find_files, {})
      vim.keymap.set('n', '<leader>a', builtin.live_grep, {})
      -- vim.keymap.set('n', '<leader>a', ':Ag<Space>', {})
      vim.keymap.set('n', '<leader>b', builtin.buffers, {})
      vim.keymap.set('n', '<leader>r', builtin.registers, {})
    end,
  }
}
