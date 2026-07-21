" ~/.vimrc

" ---------------------------------------------------------------------------
" Copier tout yank (y) vers le presse-papier systeme
" ---------------------------------------------------------------------------
" Session Wayland + ce vim compile sans clipboard natif (-clipboard,
" -wayland_clipboard) : on pipe le texte yanke vers wl-copy. Resultat : apres
" un 'y' (yy, yw, y$, 3yy...) dans vim, Ctrl-V colle dans les autres apps.
"
" Ne se declenche que sur un YANK (operateur 'y'), pas sur les suppressions
" (d, x, c) : ainsi un 'dd' dans vim n'ecrase pas ton presse-papier.
" Pour inclure aussi les suppressions, retire le test 'v:event.operator'.
if executable('wl-copy')
  function! s:YankToClipboard() abort
    if v:event.operator ==# 'y'
      call system('wl-copy', join(v:event.regcontents, "\n"))
    endif
  endfunction

  augroup YankToClipboard
    autocmd!
    autocmd TextYankPost * call s:YankToClipboard()
  augroup END
endif

" Bonus : coller le presse-papier systeme DANS vim avec <leader>p (par defaut
" leader = \ , donc \p ). Insere le contenu de wl-paste sous le curseur.
nnoremap <leader>p :read !wl-paste --no-newline<CR>
