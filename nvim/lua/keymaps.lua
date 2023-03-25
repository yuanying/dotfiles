local M = {}

function M.setup()
  vim.g.mapleader = " "
  vim.keymap.set('n', '<Leader>', '<Nop>')
  vim.keymap.set('n', 'ZZ', '<Nop>')
  vim.keymap.set('n', 'ZQ', '<Nop>')
  vim.keymap.set('n', 'q', '<Nop>')
  vim.keymap.set('n', 'Q', '<Nop>')

  -- Emacs Style
  vim.keymap.set('c', '<C-B>', '<Left>')
  vim.keymap.set('c', '<C-F>', '<Right>')
  vim.keymap.set('c', '<C-A>', '<Home>')
  vim.keymap.set('c', '<C-E>', '<End>')
  vim.keymap.set('c', '<A-b>', '<S-Left>')
  vim.keymap.set('c', '<A-f>', '<S-Right>')
  vim.keymap.set('c', '<C-p>', '<Up>')
  vim.keymap.set('c', '<C-n>', '<Down>')

  vim.keymap.set('i', '<C-B>', '<Left>')
  vim.keymap.set('i', '<C-F>', '<Right>')
  vim.keymap.set('i', '<C-A>', '<Home>')
  vim.keymap.set('i', '<C-E>', '<End>')
  vim.keymap.set('i', '<A-b>', '<S-Left>')
  vim.keymap.set('i', '<A-f>', '<S-Right>')
  vim.keymap.set('i', '<A-p>', '<Up>')
  vim.keymap.set('i', '<A-n>', '<Down>')

  -- keymap prefix
  vim.keymap.set('n', '[LSP]', '<Nop>')
  vim.keymap.set('n', '<Leader>l', '[LSP]', { remap = true })
  vim.keymap.set('n', '[GIT]', '<Nop>')
  vim.keymap.set('n', '<Leader>g', '[GIT]', { remap = true })
  vim.keymap.set('n', '[BUFFER]', '<Nop>')
  vim.keymap.set('n', '<Leader>g', '[BUFFER]', { remap = true })
end

return M