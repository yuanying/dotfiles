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

" Plug 'cocopon/iceberg.vim'
" Plug 'fatih/molokai'
" Plug 'morhetz/gruvbox'
" Plug 'sjl/badwolf'
" Plug 'mattn/vim-goimports'
Plug 'airblade/vim-gitgutter'
Plug 'cohama/lexima.vim'
Plug 'edkolev/tmuxline.vim'
Plug 'junegunn/fzf', { 'do': './install --bin' }
Plug 'junegunn/fzf.vim'
Plug 'kana/vim-tabpagecd'
Plug 'lambdalisue/fern-mapping-project-top.vim'
Plug 'lambdalisue/fern-renderer-devicons.vim'
Plug 'lambdalisue/fern.vim'
Plug 'ryanoasis/vim-devicons'
Plug 'tpope/vim-bundler'
Plug 'tpope/vim-endwise'
Plug 'tpope/vim-fugitive'
Plug 'tyru/caw.vim'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'yuanying/tender.vim', { 'branch': 'dev' }

" vim-lsp
Plug 'prabirshrestha/asyncomplete.vim'
Plug 'prabirshrestha/async.vim'
Plug 'prabirshrestha/vim-lsp'
Plug 'prabirshrestha/asyncomplete-lsp.vim'
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
" set concealcursor=
set completeopt=menu,menuone
if (has("termguicolors"))
  set termguicolors
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
endif

" colorscheme gruvbox
" set background=dark
" let g:gruvbox_contrast_dark="hard"
" "let g:airline_statusline_ontop=1
" let g:airline_theme='gruvbox'
let g:airline_powerline_fonts = 1
" colorscheme goodwolf
" colorscheme badwolf
" let g:airline_theme='badwolf'
" colorscheme molokai
" let g:airline_theme='molokai'
colorscheme tender
" colorscheme iceberg
let hostname = substitute(system('hostname'), '\n', '', '')
if hostname == "router"
    let g:airline_theme='badwolf'
elseif hostname =~ "Z\-MAC"
    let g:airline_theme='molokai'
else
    let g:airline_theme='tender'
endif

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
set path=$PWD/**

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

" fzf and ag
nmap <Leader>b :Buffers<CR>
nmap <Leader>t :Files<CR>
nmap <Leader>r :Tags<CR>
command! -bang -nargs=* Ag
\ call fzf#vim#grep(
\   'ag --nogroup --column --color '.shellescape(<q-args>), 1,
\   fzf#vim#with_preview(),
\   <bang>0)
nnoremap <Leader>a :Ag<Space>
command! -bang -nargs=? -complete=dir Files
  \ call fzf#vim#files(<q-args>, fzf#vim#with_preview(), <bang>0)
" command! -bar -bang -nargs=? -complete=buffer buffers
"  \ call fzf#vim#buffers(<q-args>, fzf#vim#with_preview(), <bang>0)

" caw
nmap <C-\> <Plug>(caw:hatpos:toggle)
vmap <C-\> <Plug>(caw:hatpos:toggle)

" gitgutter
nmap ]h <Plug>(GitGutterNextHunk)
nmap [h <Plug>(GitGutterPrevHunk)
let g:gitgutter_sign_added = '·'
let g:gitgutter_sign_modified = '·'
let g:gitgutter_sign_removed = '·'
let g:gitgutter_sign_removed_first_line = '·'
let g:gitgutter_sign_modified_removed = '·'

" nerdtree
"let NERDTreeShowHidden=1
"noremap <silent><C-e> :NERDTreeToggle<CR>
noremap <silent><C-e> :Fern . -drawer -toggle<CR>
let g:fern#renderer = "devicons"
function! s:init_fern() abort
  set nonumber
  set noruler
  nmap <buffer> <Enter> <Plug>(fern-open-or-expand)
  nmap <buffer> l <Plug>(fern-action-open)<C-w><C-p>
endfunction

augroup fern-custom
  autocmd! *
  autocmd FileType fern call s:init_fern()
augroup END


" vim-lsp
let g:asyncomplete_auto_popup = 1
let g:asyncomplete_popup_delay = 200
let g:lsp_async_completion = 1
let g:lsp_diagnostics_echo_cursor = 1
let g:lsp_diagnostics_echo_delay = 2000
let g:lsp_diagnostics_float_delay = 2000
let g:lsp_log_file = ""
let g:lsp_log_verbose = 0
let g:lsp_preview_keep_focus = 0
let g:lsp_signs_error = {'text': '✗'}
let g:lsp_signs_warning = {'text': '‼'}
nmap <silent> <Leader>ld <plug>(lsp-peek-definition)
nmap <silent> <Leader>lD <plug>(lsp-definition)
nmap <silent> <Leader>lt <plug>(lsp-peek-type-definition)
nmap <silent> <Leader>lT <plug>(lsp-type-definition)
nmap <silent> <Leader>lr <plug>(lsp-references)
nmap <silent> <Leader>lR <plug>(lsp-rename)
nmap <silent> <Leader>lh <plug>(lsp-hover)
nmap <silent> <Leader>lf <plug>(lsp-document-format)
nmap <silent> <Leader>le <plug>(lsp-next-error)

" vim-lsp golang
if executable('gopls')
  augroup LspGo
    au!
    autocmd User lsp_setup call lsp#register_server({
        \ 'name': 'go-lang',
        \ 'cmd': {server_info->['gopls']},
        \ 'whitelist': ['go'],
        \ 'workspace_config': {'gopls': {
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

function! s:install_lsp_format()
  augroup lsp_autoformat
    au! * <buffer>
    autocmd BufWritePre <buffer> LspDocumentFormatSync
  augroup END
endfunction

augroup lsp_format_install
  au!
  autocmd FileType go call s:install_lsp_format()
augroup END

" Strip space
function! Rstrip()
  let s:tmppos = getpos(".")
  if &filetype == "markdown"
    %s/\v(\s{2})?(\s+)?$/\1/e
    match Underlined /\s\{2}$/
  else
    %s/\v\s+$//e
  endif
  call setpos(".", s:tmppos)
endfunction

autocmd BufWritePre * :call Rstrip()

function! s:get_syn_id(transparent)
  let synid = synID(line("."), col("."), 1)
  if a:transparent
    return synIDtrans(synid)
  else
    return synid
  endif
endfunction
function! s:get_syn_attr(synid)
  let name = synIDattr(a:synid, "name")
  let ctermfg = synIDattr(a:synid, "fg", "cterm")
  let ctermbg = synIDattr(a:synid, "bg", "cterm")
  let guifg = synIDattr(a:synid, "fg", "gui")
  let guibg = synIDattr(a:synid, "bg", "gui")
  return {
        \ "name": name,
        \ "ctermfg": ctermfg,
        \ "ctermbg": ctermbg,
        \ "guifg": guifg,
        \ "guibg": guibg}
endfunction
function! s:get_syn_info()
  let baseSyn = s:get_syn_attr(s:get_syn_id(0))
  echo "name: " . baseSyn.name .
        \ " ctermfg: " . baseSyn.ctermfg .
        \ " ctermbg: " . baseSyn.ctermbg .
        \ " guifg: " . baseSyn.guifg .
        \ " guibg: " . baseSyn.guibg
  let linkedSyn = s:get_syn_attr(s:get_syn_id(1))
  echo "link to"
  echo "name: " . linkedSyn.name .
        \ " ctermfg: " . linkedSyn.ctermfg .
        \ " ctermbg: " . linkedSyn.ctermbg .
        \ " guifg: " . linkedSyn.guifg .
        \ " guibg: " . linkedSyn.guibg
endfunction
command! SyntaxInfo call s:get_syn_info()

