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
Plug 'https://github.com/scrooloose/nerdtree.git'
Plug 'https://github.com/tpope/vim-bundler.git'
Plug 'https://github.com/tpope/vim-endwise.git'

" vim-lsp
Plug 'https://github.com/prabirshrestha/asyncomplete.vim.git'
Plug 'https://github.com/prabirshrestha/async.vim.git'
Plug 'https://github.com/prabirshrestha/vim-lsp.git'
Plug 'https://github.com/prabirshrestha/asyncomplete-lsp.vim.git'
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
set clipboard=unnamedplus,unnamed
set concealcursor=
set completeopt=menu,menuone
try
    colorscheme gruvbox
    set background=dark
catch /^Vim\%((\a\+)\)\=:E185/
    colorscheme default
    set background=dark
endtry

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
"set autochdir

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

""" KeyMap
let mapleader = "\<Space>"
cnoremap <C-p> <Up>
cnoremap <C-n> <Down>

" emacs like keys
cnoremap <C-B> <Left>
cnoremap <C-F> <Right>
cnoremap <C-A> <Home>
cnoremap <C-E> <End>
cnoremap <A-b> <S-Left>
cnoremap <A-f> <S-Right>

inoremap <C-A> <Home>
inoremap <C-B> <Left>
inoremap <C-D> <Del>
inoremap <C-E> <End>
inoremap <C-F> <Right>
inoremap <A-n> <Down>
inoremap <A-p> <Up>
inoremap <A-b> <S-Left>
inoremap <A-f> <S-Right>

" Operate buffer
nnoremap <silent> bp :bp<CR>
nnoremap <silent> bn :bn<CR>

" nerdtree
let NERDTreeShowHidden=1
noremap <silent><C-e> :NERDTreeToggle<CR>

" vim-lsp
let g:asyncomplete_auto_popup = 1
let g:lsp_async_completion = 1
let g:lsp_log_verbose = 0
nmap <silent> <Leader>ld <plug>(lsp-peek-definition)
nmap <silent> <Leader>lD <plug>(lsp-definition)
nmap <silent> <Leader>lt <plug>(lsp-peek-type-definition)
nmap <silent> <Leader>lT <plug>(lsp-type-definition)
nmap <silent> <Leader>lr <plug>(lsp-references)
nmap <silent> <Leader>lR <plug>(lsp-rename)
nmap <silent> <Leader>lh <plug>(lsp-hover)
nmap <silent> <Leader>lf <plug>(lsp-document-format)

" vim-lsp golang
if executable('gopls')
  augroup LspGo
    au!
    autocmd User lsp_setup call lsp#register_server({
        \ 'name': 'go-lang',
        \ 'cmd': {server_info->['gopls']},
        \ 'whitelist': ['go'],
        \ 'workspace_config': {'gopls': {
        \     'staticcheck': v:true,
        \     'completeUnimported': v:true,
        \     'caseSensitiveCompletion': v:true,
        \     'usePlaceholders': v:true,
        \     'completionDocumentation': v:true,
        \     'watchFileChanges': v:true,
        \     'hoverKind': 'SingleLine',
        \   }},
        \ })
    autocmd FileType go setlocal omnifunc=lsp#complete
  augroup END
endif

