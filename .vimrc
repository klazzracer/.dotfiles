" ~/.vimrc

" ---------------------------------------------------------------------------
" Reglages par defaut de Vim (coloration syntaxique, detection de type...)
" ---------------------------------------------------------------------------
" Tant qu'aucun ~/.vimrc n'existe, Vim charge tout seul $VIMRUNTIME/defaults.vim
" (syntax on, filetype detection, couleurs pour .sh, .kdl, etc.). Des qu'un
" ~/.vimrc existe, ce chargement automatique s'arrete -> on le refait ici pour
" retrouver les couleurs.
unlet! skip_defaults_vim
source $VIMRUNTIME/defaults.vim

" Ceinture + bretelles : garantit coloration et detection de type de fichier.
syntax on
filetype plugin indent on

" ---------------------------------------------------------------------------
" Couleurs / theme
" ---------------------------------------------------------------------------
" Embark (https://github.com/embark-theme/vim) installe dans
" ~/.vim/pack/themes/start/embark -- charge automatiquement par vim 8+,
" aucun gestionnaire de plugins necessaire.
"
" Embark exige le truecolor : termguicolors DOIT etre actif avant le
" colorscheme, sinon les couleurs 24 bits sont ignorees.
set termguicolors
set background=dark
colorscheme PaperColor

" ---------------------------------------------------------------------------
" Presse-papier systeme
" ---------------------------------------------------------------------------
" Paquet gvim (vim +clipboard +wayland_clipboard) : y / d / p utilisent
" directement le presse-papier systeme. Ctrl-V colle dans les autres apps,
" et p colle ce que tu as copie ailleurs.
set clipboard=unnamedplus

function! OSC52Yank()
    let buffer = system('base64 -w0', getreg('"'))
    let osc52 = "\e]52;c;" . buffer . "\x07"
    " Write directly to the terminal device bypasses the lack of v:stderr
    call writefile([osc52], '/dev/tty', 'b')
endfunction

autocmd TextYankPost * if v:event.regname == '' | call OSC52Yank() | endif

