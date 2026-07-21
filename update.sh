#!/usr/bin/env bash
#
# update.sh — synchronise les dotfiles entre $HOME et le depot ~/.dotfiles
#
#   update.sh --copy      $HOME  -> depot    (sauvegarde tes configs dans git)
#   update.sh --upgrade   depot  -> $HOME    (deploie ; snapshot auto avant)
#   update.sh --restore   annule le dernier --upgrade (restaure le snapshot)
#   update.sh --list      liste les elements geres et l'etat des snapshots
#   update.sh --help
#
# Sans argument : menu interactif (fleches + Entree).
#
# Le rollback : avant chaque --upgrade, l'etat courant est copie dans
# ~/.dotfiles/.backups/<AAAAMMJJ-HHMMSS>/ (hors des dossiers de config, pour ne
# pas gener les apps). --restore rejoue le snapshot le plus recent.
# ---------------------------------------------------------------------------

set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
BACKUPS="$DOTFILES/.backups"

# --- Elements geres : chemins relatifs a $HOME (== relatifs au depot).
#     Fichier ou dossier. Ajoute-en librement (ex: ".config/fish").
ITEMS=(
    ".vimrc"
    ".config/niri"
    ".config/noctalia"
    ".config/fish"
)

# --- Couleurs (desactivees si la sortie n'est pas un terminal)
if [[ -t 1 ]]; then
    C_TITLE=$'\e[1;36m'; C_KEY=$'\e[1;33m'; C_DIM=$'\e[2m'
    C_SEL=$'\e[7m'; C_OFF=$'\e[0m'
else
    C_TITLE=''; C_KEY=''; C_DIM=''; C_SEL=''; C_OFF=''
fi

log() { printf '  %s\n' "$*"; }
die() { printf 'update.sh: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,15p' "$0" | sed 's/^#\s\{0,1\}//'
}

# mirror SRC DST : copie exacte de SRC (fichier ou dossier) vers DST.
# rsync pour un miroir propre ; le parent de DST est cree au besoin.
mirror() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [[ -d "$src" ]]; then
        rm -rf "$dst"
        rsync -a "$src/" "$dst/"
    else
        rsync -a "$src" "$dst"
    fi
}

cmd_copy() {
    log "Copie  \$HOME  ->  depot ($DOTFILES)"
    local rel n=0
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$HOME/$rel" ]]; then
            mirror "$HOME/$rel" "$DOTFILES/$rel"
            log "sauve   : $rel"; n=$((n + 1))
        else
            log "absent  : $rel (ignore)"
        fi
    done
    log "$n element(s) copie(s) dans le depot."
}

cmd_upgrade() {
    local stamp snap rel
    stamp="$(date +%Y%m%d-%H%M%S)"
    snap="$BACKUPS/$stamp"

    log "Snapshot des configs actuelles  ->  .backups/$stamp"
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$HOME/$rel" ]]; then
            mirror "$HOME/$rel" "$snap/$rel"
        else
            # marque l'absence : --restore devra re-supprimer si --upgrade le cree
            mkdir -p "$snap"
            printf '%s\n' "$rel" >> "$snap/.absents"
        fi
    done
    printf '%s\n' "$stamp" > "$BACKUPS/last"

    log "Deploiement  depot  ->  \$HOME"
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$DOTFILES/$rel" ]]; then
            mirror "$DOTFILES/$rel" "$HOME/$rel"
            log "applique : $rel"
        else
            log "absent du depot : $rel (ignore)"
        fi
    done
    log "Termine. Annuler avec :  update.sh --restore"
}

cmd_restore() {
    [[ -f "$BACKUPS/last" ]] || die "aucun snapshot — fais d'abord un --upgrade"
    local stamp snap rel
    stamp="$(cat "$BACKUPS/last")"
    snap="$BACKUPS/$stamp"
    [[ -d "$snap" ]] || die "snapshot introuvable : $snap"

    log "Restauration du snapshot $stamp  ->  \$HOME"
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$snap/$rel" ]]; then
            mirror "$snap/$rel" "$HOME/$rel"
            log "restaure : $rel"
        elif [[ -f "$snap/.absents" ]] && grep -qxF "$rel" "$snap/.absents"; then
            # cet element n'existait pas avant le --upgrade : on le retire
            rm -rf "$HOME/$rel"
            log "retire   : $rel (n'existait pas avant)"
        fi
    done
    log "Termine."
}

cmd_list() {
    log "Depot   : $DOTFILES"
    log "Elements geres :"
    local rel
    for rel in "${ITEMS[@]}"; do
        printf '    %-28s home:%s  depot:%s\n' "$rel" \
            "$([[ -e "$HOME/$rel" ]] && echo oui || echo NON)" \
            "$([[ -e "$DOTFILES/$rel" ]] && echo oui || echo NON)"
    done
    if [[ -f "$BACKUPS/last" ]]; then
        log "Dernier snapshot : $(cat "$BACKUPS/last")"
    else
        log "Aucun snapshot."
    fi
}

# --- Ecran d'accueil + menu interactif --------------------------------------
banner() {
    printf '\n'
    printf '  %s╭───────────────────────────────────────────────╮%s\n' "$C_TITLE" "$C_OFF"
    printf '  %s│   update.sh · gestion de mes dotfiles         │%s\n' "$C_TITLE" "$C_OFF"
    printf '  %s╰───────────────────────────────────────────────╯%s\n' "$C_TITLE" "$C_OFF"
    printf '\n'
    printf '  Synchronise mes fichiers de config (vim, niri, noctalia,\n'
    printf '  fish) entre ce systeme et mon depot git ~/.dotfiles.\n'
    printf '  Chaque deploiement fait un snapshot pour pouvoir revenir\n'
    printf '  en arriere.\n\n'
    printf '  %sQue veux-tu faire ?%s\n\n' "$C_TITLE" "$C_OFF"
}

# labels affiches, alignes avec MENU_KEYS / MENU_FN
MENU_KEYS=("--copy" "--upgrade" "--restore" "--list" "Quitter")
MENU_FN=("cmd_copy" "cmd_upgrade" "cmd_restore" "cmd_list" "__quit__")
MENU_DESC=(
    "Sauvegarder   \$HOME  ->  depot git"
    "Deployer      depot git  ->  \$HOME   (snapshot avant)"
    "Restaurer     annuler le dernier --upgrade (rollback)"
    "Etat          lister les configs et le dernier snapshot"
    "Sortir de l'application"
)

draw_menu() {
    local sel="$1" i
    for i in "${!MENU_KEYS[@]}"; do
        if (( i == sel )); then
            printf '   %s ▶ %-10s %s %s\n' \
                "$C_SEL" "${MENU_KEYS[i]}" "${MENU_DESC[i]}" "$C_OFF"
        else
            printf '     %s%-10s%s %s%s%s\n' \
                "$C_KEY" "${MENU_KEYS[i]}" "$C_OFF" "$C_DIM" "${MENU_DESC[i]}" "$C_OFF"
        fi
    done
    printf '\n  %s↑/↓ choisir · Entree valider · q quitter%s' "$C_DIM" "$C_OFF"
}

# Selection interactive (fleches). Renvoie l'index choisi dans REPLY_SEL,
# ou -1 si l'utilisateur quitte (q / Echap).
select_action() {
    local sel="${1:-0}" n=${#MENU_KEYS[@]} key rest
    printf '\e[?25l'                         # cache le curseur
    printf '\e7'                             # sauve la position (DECSC)
    while true; do
        printf '\e8'                         # revient a la position (DECRC)
        draw_menu "$sel"
        IFS= read -rsn1 key || { key=q; }
        if [[ $key == $'\e' ]]; then
            read -rsn2 -t 0.05 rest || rest=''
            case $rest in
                '[A') sel=$(( (sel - 1 + n) % n )) ;;   # haut
                '[B') sel=$(( (sel + 1) % n )) ;;       # bas
                '')   sel=-1; break ;;                  # Echap seul = quitter
            esac
        elif [[ -z $key ]]; then break        # Entree
        elif [[ $key == q || $key == Q ]]; then sel=-1; break
        fi
    done
    printf '\e[?25h'                          # remet le curseur
    REPLY_SEL=$sel
}

run_menu() {
    # Pas de TTY (pipe, cron...) : on retombe sur l'aide texte.
    if [[ ! -t 0 || ! -t 1 ]]; then
        usage
        return 0
    fi

    local last=0 k
    while true; do
        printf '\e[H\e[2J'                    # efface l'ecran
        banner
        select_action "$last"
        (( REPLY_SEL < 0 )) && break          # q / Echap
        last=$REPLY_SEL
        [[ ${MENU_FN[REPLY_SEL]} == __quit__ ]] && break   # 5e choix : Quitter

        printf '\n\n'
        # Sous-shell : un 'die'/exit dans l'action ne tue pas le menu.
        ( "${MENU_FN[REPLY_SEL]}" ) || true

        printf '\n  %s— Entree : revenir au menu · q : quitter —%s ' "$C_DIM" "$C_OFF"
        IFS= read -rsn1 k || k=q
        [[ $k == q || $k == Q ]] && break
    done
    printf '\n'
    log "A bientot."
}

case "${1:-}" in
    --copy)      cmd_copy ;;
    --upgrade)   cmd_upgrade ;;
    --restore)   cmd_restore ;;
    --list)      cmd_list ;;
    -h|--help)   usage ;;
    "")          run_menu ;;
    *) die "option inconnue : $1  (voir --help)" ;;
esac
