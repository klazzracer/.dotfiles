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
" Presse-papier systeme
" ---------------------------------------------------------------------------
" Paquet gvim (vim +clipboard +wayland_clipboard) : y / d / p utilisent
" directement le presse-papier systeme. Ctrl-V colle dans les autres apps,
" et p colle ce que tu as copie ailleurs.
set clipboard=unnamedplus
