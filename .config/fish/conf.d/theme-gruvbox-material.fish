# Theme fish "Gruvbox Material Medium" — gere par ~/.dotfiles, commun aux deux machines.
# Couleurs explicites (hex) plutot que les noms ANSI : avec la palette Gruvbox,
# blue (#7daea3) et cyan (#89b482) sont presque identiques, d'ou commandes et
# arguments indiscernables. Ici chaque element a sa propre teinte.
#
#   commande   vert    #a9b665 gras      option (-x --xx)  mauve   #d3869b
#   argument   texte   #d4be98           chaine 'a' "b"    jaune   #d8a657
#   | ; &      orange  #e78a4e           > < redirection   aqua    #89b482
#   * ~ $var   bleu    #7daea3           erreur            rouge   #ea6962
#   commentaire gris   #928374 italique  suggestion        #7c6f64

set -g fish_color_normal          d4be98
set -g fish_color_command         a9b665 --bold
set -g fish_color_keyword         ea6962 --bold
set -g fish_color_param           d4be98
set -g fish_color_option          d3869b
set -g fish_color_quote           d8a657
set -g fish_color_redirection     89b482 --bold
set -g fish_color_end             e78a4e --bold
set -g fish_color_operator        7daea3
set -g fish_color_escape          89b482
set -g fish_color_error           ea6962
set -g fish_color_comment         928374 --italics
set -g fish_color_autosuggestion  7c6f64
set -g fish_color_valid_path      --underline
set -g fish_color_cancel          -r
set -g fish_color_search_match    --background=3c3836
set -g fish_color_selection       d4be98 --bold --background=45403d
set -g fish_color_history_current --bold
set -g fish_color_cwd             a9b665
set -g fish_color_cwd_root        ea6962
set -g fish_color_user            a9b665
set -g fish_color_host            d4be98
set -g fish_color_host_remote     d8a657
set -g fish_color_status          ea6962

set -g fish_pager_color_completion          d4be98
set -g fish_pager_color_description         928374 --italics
set -g fish_pager_color_prefix              a9b665 --bold --underline
set -g fish_pager_color_progress            282828 --background=d8a657
set -g fish_pager_color_selected_background --background=3c3836
set -g fish_pager_color_selected_prefix     a9b665 --bold --underline
set -g fish_pager_color_secondary_background --background=282828
