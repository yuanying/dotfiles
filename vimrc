if has('vim_starting')
  set rtp+=~/.vim/plugged/vim-plug
  if !isdirectory(expand('~/.vim/plugged/vim-plug'))
    echo 'Install vim-plug...'
    call system('mkdir -p ~/.vim/plugged/vim-plug')
    call system('git clone git://github.com/junegunn/vim-plug.git ~/.vim/plugged/vim-plug/autoload')
  end

  if !isdirectory(expand('~/.vim-bak'))
    echo 'Create ~/.vim-bak directory for backup...'
    call system('mkdir -p ~/.vim-bak')
  end
endif

call plug#begin('~/.vim/plugged')
Plug 'junegunn/vim-plug', {'dir': '~/.vim/plugged/vim-plug/autoload'}

Plug 'https://github.com/morhetz/gruvbox.git'
call plug#end()

""" Encoding
set encoding=utf-8
set fileencoding=utf-8

""" Display
set number
set ruler
set laststatus=2
set list
set listchars=tab:>-,trail:_
set linespace=0
set showcmd
set cmdheight=1
set showmatch
syntax on
set hlsearch
set foldmethod=marker
set cursorline
set t_Co=256
colorscheme gruvbox
set clipboard=unnamedplus,unnamed
set concealcursor=
set completeopt=menu,menuone

""" Backup
set backup
set backupdir=$HOME/.vim-bak/
set swapfile
set directory=$HOME/.vim-bak/
set viewdir=$HOME/.vim/view/

""" Tab
set tabstop=4
set softtabstop=4
set shiftwidth=4
set expandtab
set shiftround

augroup fileTypeIndent
    autocmd!
    autocmd FileType yaml      setlocal tabstop=2 softtabstop=2 shiftwidth=2
    autocmd FileType ruby      setlocal tabstop=2 softtabstop=2 shiftwidth=2
augroup END

""" Indent
set autoindent
set backspace=indent,eol,start
set smartindent

""" File
set autoread
set hidden
set autochdir

""" Search
set ignorecase
set smartcase
set wrapscan
set incsearch

""" History
set history=100

""" Complete
set infercase
set wildmenu
set wildmode=list:longest,full

""" Modeline
set modeline
set modelines=5

""" FileType
filetype plugin indent on


