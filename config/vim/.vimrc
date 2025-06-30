set smartindent
set tabstop=4
set shiftwidth=4
set expandtab
set pastetoggle=<F3>

colorscheme molokai
  	set t_Co=256
  	let g:rehash256 = 1

	set encoding=utf-8
	set fileencodings=utf-8,cp950
  	set tabstop=4
  	set shiftwidth=4
	set ruler
	set hlsearch
	set incsearch
	set number
	set cursorline

	set laststatus=1
	set statusline=%4*%<\%m%<[%f\%r%h%w]\ [%{&ff},%{&fileencoding},%Y]%=\[Position=%l,%v,%p%%]

" Moving Lines
" Normal mode
nnoremap <C-j> :m .+1<CR>==
nnoremap <C-k> :m .-2<CR>==

" Insert mode
inoremap <C-j> <ESC>:m .+1<CR>==gi
inoremap <C-k> <ESC>:m .-2<CR>==gi

" Visual mode
vnoremap <C-j> :m '>+1<CR>gv=gv
vnoremap <C-k> :m '<-2<CR>gv=gv
