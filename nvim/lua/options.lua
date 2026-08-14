local M = {}

-- mosh / ssh 越しのコンテナには X も Wayland も無く、xsel や wl-copy が
-- 動かないので unnamedplus が機能しない。かわりに OSC 52 でホスト端末
-- (Ghostty) のクリップボードへ書く。herdr も mosh も OSC 52 を素通しする。
--
-- Neovim には SSH_TTY を見て自動で OSC 52 を使う仕組みがあるが、端末が
-- 対応しているかを問い合わせで判定するため herdr / mosh 越しでは有効に
-- ならない (provider#clipboard#Executable() が空になる)。明示的に張る。
--
-- paste 側は端末への読み出し問い合わせになり、Ghostty は既定でこれを
-- 拒否する。応答待ちで固まるのを避けるため、直前に自分が copy した内容を
-- 返すだけにする。ホスト側でコピーした文字列は端末のペースト操作で入れる。
function M.setup_osc52_clipboard()
  if not vim.env.SSH_TTY then
    return
  end

  local osc52 = require('vim.ui.clipboard.osc52')
  local cache = { lines = {}, regtype = '' }

  local function copy(reg)
    local send = osc52.copy(reg)
    return function(lines, regtype)
      cache = { lines = lines, regtype = regtype }
      send(lines, regtype)
    end
  end

  local function paste()
    return { cache.lines, cache.regtype }
  end

  vim.g.clipboard = {
    name = 'OSC 52',
    copy = { ['+'] = copy('+'), ['*'] = copy('*') },
    paste = { ['+'] = paste, ['*'] = paste },
  }
end

function M.setup()
  vim.opt.encoding = 'UTF-8'
  vim.scriptencoding = 'utf-8'
  vim.opt.backspace= {"indent", "eol", "start"}
  vim.opt.display = {"lastline", "msgsep"}
  vim.opt.hidden = true
  vim.opt.hlsearch = true
  vim.opt.linebreak = true
  vim.opt.ruler = true
  vim.opt.termguicolors = true
  vim.opt.wildmenu = true
  vim.opt.wildmode = "full"
  vim.opt.inccommand = "split"
  vim.opt.maxmempattern = 20000
  vim.opt.updatetime = 100
  vim.opt.number = true
  vim.opt.relativenumber = true
  vim.opt.showcmd = false
  vim.opt.showmode = false
  vim.opt.emoji = true
  vim.opt.ambiwidth = "single"
  vim.opt.fileformats = {"unix", "dos", "mac"}
  vim.opt.foldcolumn = "0"
  vim.opt.signcolumn = "yes"
  vim.opt.laststatus = 3
  -- vim.opt.cmdheight = 0
  vim.opt.showtabline = 2
  vim.opt.breakindent = true
  vim.opt.binary = true
  vim.opt.eol = true
  vim.opt.clipboard:append{'unnamedplus'}
  vim.opt.clipboard:append{'unnamed'}
  M.setup_osc52_clipboard()
  vim.opt.list = true
  vim.opt.listchars = {tab='»-', trail='-', eol='↲', extends='»', precedes='«', nbsp='%', space='.'}

  -- tab
  vim.opt.tabstop = 4
  vim.opt.softtabstop = 4
  vim.opt.shiftwidth = 4
  vim.opt.expandtab = true

  vim.g.netrw_fastbrowse = 0

  vim.diagnostic.config({
    virtual_text = false
  })

  -- Show line diagnostics automatically in hover window
  vim.o.updatetime = 250
  vim.cmd [[autocmd CursorHold,CursorHoldI * lua vim.diagnostic.open_float(nil, {focus=false})]]

  -- set t_ut=
  -- set t_8f=\<Esc>38;2;%lu;%lu;%lum
  -- set t_8b=\<Esc>48;2;%lu;%lu;%lum
end

return M
