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
    ".config/nano"
    ".config/hypr"
    ".config/kitty"
    ".vim"
)

# --- Les dossiers .git internes sont ignores partout (copie, comparaison).
#     Raison : ~/.vim/pack/themes/start/* sont des depots git clones. Git
#     refuse d'imbriquer un depot dans un autre (il n'enregistrerait qu'un
#     gitlink, sans le contenu -> themes perdus). On copie donc les fichiers
#     sans leur .git, ce qui suffit : un theme vim est du texte, pas un depot.
RSYNC_EXCL=(--exclude '.git/')

# --- Couleurs (desactivees si la sortie n'est pas un terminal)
if [[ -t 1 ]]; then
    C_TITLE=$'\e[1;36m'; C_KEY=$'\e[1;33m'; C_DIM=$'\e[2m'
    C_SEL=$'\e[7m'; C_OFF=$'\e[0m'
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'
else
    C_TITLE=''; C_KEY=''; C_DIM=''; C_SEL=''; C_OFF=''
    C_OK=''; C_WARN=''; C_ERR=''
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
        rsync -a "${RSYNC_EXCL[@]}" "$src/" "$dst/"
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

# newest PATH : epoch du fichier le plus recent sous PATH (vide si absent)
newest() {
    [[ -e "$1" ]] || return 0
    if [[ -d "$1" ]]; then
        find "$1" -type f -not -path '*/.git/*' -printf '%T@\n' 2>/dev/null | sort -rn | head -n1 || true
    else
        stat -c '%Y' "$1" 2>/dev/null || true
    fi
}

# fmtdate EPOCH : 'AAAA-MM-JJ HH:MM' (— si vide)
fmtdate() {
    [[ -z $1 ]] && { printf '%s' '—'; return; }
    date -d "@${1%.*}" '+%Y-%m-%d %H:%M'
}

# datecolors MH MD -> DCH / DCD : vert sur la date la plus recente, blanc sur
# l'autre (rien si les deux sont vides ou de meme date).
datecolors() {
    DCH=''; DCD=''
    local a="${1%.*}" b="${2%.*}"
    if   [[ -z $1 && -z $2 ]]; then return
    elif [[ -z $2 ]]; then DCH=$C_OK
    elif [[ -z $1 ]]; then DCD=$C_OK
    elif (( a > b )); then DCH=$C_OK
    elif (( b > a )); then DCD=$C_OK
    fi
}

# list_diffs H D : imprime, indentes, les fichiers qui different entre H et D
# avec leurs dates (systeme / depot). Nom en vert, date la plus recente en vert.
list_diffs() {
    local h="$1" d="$2" rel hp dp mh md tag
    local -a rels=()
    if [[ -d "$h" || -d "$d" ]]; then
        while IFS= read -r rel; do rels+=("$rel"); done < <(
            { [[ -d "$h" ]] && ( cd "$h" && find . -type f -not -path './.git/*' -not -path '*/.git/*' -printf '%P\n' )
              [[ -d "$d" ]] && ( cd "$d" && find . -type f -not -path './.git/*' -not -path '*/.git/*' -printf '%P\n' ) ; } \
              2>/dev/null | sort -u )
    else
        rels=("")                              # element = fichier simple
    fi
    for rel in "${rels[@]}"; do
        hp="$h${rel:+/$rel}"; dp="$d${rel:+/$rel}"
        [[ -e "$hp" || -e "$dp" ]] || continue
        if [[ -f "$hp" && -f "$dp" ]] && cmp -s "$hp" "$dp"; then continue; fi
        mh=$( [[ -e "$hp" ]] && stat -c '%Y' "$hp" 2>/dev/null || true )
        md=$( [[ -e "$dp" ]] && stat -c '%Y' "$dp" 2>/dev/null || true )
        if   [[ -z $md ]]; then tag="depot: absent"
        elif [[ -z $mh ]]; then tag="systeme: absent"
        elif (( ${mh%.*} > ${md%.*} )); then tag="systeme +recent"
        elif (( ${md%.*} > ${mh%.*} )); then tag="depot +recent"
        else tag="different (meme date)"
        fi
        datecolors "$mh" "$md"
        printf '    %s%-18s%s %s%-17s%s %s%-17s%s %s\n' \
            "$C_OK" "${rel:-$(basename "$h")}" "$C_OFF" \
            "$DCH" "$(fmtdate "$mh")" "$C_OFF" \
            "$DCD" "$(fmtdate "$md")" "$C_OFF" "$tag"
    done
}

cmd_list() {
    log "Depot : $DOTFILES"
    printf '\n  %-20s %-17s %-17s %s\n' "Element" "systeme" "depot" "etat"
    printf '  %-20s %-17s %-17s %s\n' "--------------------" "-----------------" "-----------------" "----"
    local rel h d mh md ih idp etat show
    for rel in "${ITEMS[@]}"; do
        h="$HOME/$rel"; d="$DOTFILES/$rel"
        mh=$(newest "$h"); md=$(newest "$d")
        ih=${mh%.*}; idp=${md%.*}; show=0
        if [[ -z $mh && -z $md ]]; then
            etat="${C_ERR}absent des deux${C_OFF}"
        elif [[ -z $md ]]; then
            etat="${C_ERR}! absent du depot   -> --copy${C_OFF}"
        elif [[ -z $mh ]]; then
            etat="${C_ERR}! absent du systeme -> --upgrade${C_OFF}"
        elif diff -rq --exclude=.git "$h" "$d" >/dev/null 2>&1; then
            etat="${C_OK}= identique${C_OFF}"
        elif (( ih > idp )); then
            etat="${C_WARN}↑ systeme plus recent -> --copy${C_OFF}"; show=1
        elif (( idp > ih )); then
            etat="${C_WARN}↓ depot plus recent   -> --upgrade${C_OFF}"; show=1
        else
            etat="${C_WARN}≠ different (meme date)${C_OFF}"; show=1
        fi
        datecolors "$mh" "$md"
        printf '  %-20s %s%-17s%s %s%-17s%s %b\n' "$rel" \
            "$DCH" "$(fmtdate "$mh")" "$C_OFF" \
            "$DCD" "$(fmtdate "$md")" "$C_OFF" "$etat"
        [[ $show == 1 ]] && list_diffs "$h" "$d"
    done
    if [[ -f "$BACKUPS/last" ]]; then
        printf '\n'; log "Dernier snapshot : $(cat "$BACKUPS/last")"
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
    printf '  fish, kitty) entre ce systeme et mon depot git ~/.dotfiles.\n'
    printf '  Chaque deploiement fait un snapshot pour pouvoir revenir\n'
    printf '  en arriere.\n\n'
    printf '  %sQue veux-tu faire ?%s\n\n' "$C_TITLE" "$C_OFF"
}

# --- Selecteur interactif generique (fleches) -------------------------------
# pick KEYS_ARR DESC_ARR [START] -> index choisi dans REPLY_SEL, ou -1 si quit.
pick() {
    local -n _keys="$1" _desc="$2"
    local sel="${3:-0}" n=${#_keys[@]} key rest i
    printf '\e[?25l\e7'                       # cache le curseur + sauve la position
    while true; do
        printf '\e8'                          # revient a la position (DECRC)
        for i in "${!_keys[@]}"; do
            if (( i == sel )); then
                printf '   %s ▶ %-10s %s %s\n' \
                    "$C_SEL" "${_keys[i]}" "${_desc[i]}" "$C_OFF"
            else
                printf '     %s%-10s%s %s%s%s\n' \
                    "$C_KEY" "${_keys[i]}" "$C_OFF" "$C_DIM" "${_desc[i]}" "$C_OFF"
            fi
        done
        printf '\n  %s↑/↓ choisir · Entree valider · q retour%s' "$C_DIM" "$C_OFF"
        IFS= read -rsn1 key || { key=q; }
        if [[ $key == $'\e' ]]; then
            read -rsn2 -t 0.05 rest || rest=''
            case $rest in
                '[A') sel=$(( (sel - 1 + n) % n )) ;;   # haut
                '[B') sel=$(( (sel + 1) % n )) ;;       # bas
                '')   sel=-1; break ;;                  # Echap seul = retour
            esac
        elif [[ -z $key ]]; then break        # Entree
        elif [[ $key == q || $key == Q ]]; then sel=-1; break
        fi
    done
    printf '\e[?25h'                          # remet le curseur
    REPLY_SEL=$sel
}

pause_menu() {   # attend une touche ; renvoie 1 si l'utilisateur veut quitter
    local k
    printf '\n  %s— Entree : revenir · q : quitter —%s ' "$C_DIM" "$C_OFF"
    IFS= read -rsn1 k || k=q
    [[ $k == q || $k == Q ]]
}

# --- Sous-menu Git ----------------------------------------------------------
git_commit() {
    printf '  Message de commit : '
    local msg
    IFS= read -r msg || return 0
    [[ -z $msg ]] && { log "message vide, commit annule."; return 0; }
    ( git -C "$DOTFILES" commit -m "$msg" ) || true
}

cmd_git() {
    local keys=("Pull" "Add" "Commit" "Push" "Retour")
    local desc=(
        "git pull"
        "git add .   (tout le depot)"
        "git commit  (demande le message)"
        "git push"
        "Revenir au menu principal"
    )
    local last=0
    while true; do
        printf '\e[H\e[2J\n  %sGit%s  ·  %s\n\n' "$C_TITLE" "$C_OFF" "$DOTFILES"
        pick keys desc "$last"
        (( REPLY_SEL < 0 )) && return 0
        last=$REPLY_SEL
        [[ ${keys[REPLY_SEL]} == Retour ]] && return 0
        printf '\n\n'
        case $REPLY_SEL in
            0) ( git -C "$DOTFILES" pull ) || true ;;
            1) ( git -C "$DOTFILES" add . && log "git add . fait." ) || true ;;
            2) git_commit ;;
            3) ( git -C "$DOTFILES" push ) || true ;;
        esac
        pause_menu && return 0
    done
}

# --- Menu principal ---------------------------------------------------------
MENU_KEYS=("--copy" "--upgrade" "--restore" "--list" "--git" "Quitter")
MENU_FN=("cmd_copy" "cmd_upgrade" "cmd_restore" "cmd_list" "cmd_git" "__quit__")
MENU_DESC=(
    "Sauvegarder   \$HOME  ->  depot git"
    "Deployer      depot git  ->  \$HOME   (snapshot avant)"
    "Restaurer     annuler le dernier --upgrade (rollback)"
    "Etat          lister les configs et le dernier snapshot"
    "Git           pull / add / commit / push"
    "Sortir de l'application"
)

run_menu() {
    # Pas de TTY (pipe, cron...) : on retombe sur l'aide texte.
    if [[ ! -t 0 || ! -t 1 ]]; then
        usage
        return 0
    fi

    local last=0 fn
    while true; do
        printf '\e[H\e[2J'                    # efface l'ecran
        banner
        pick MENU_KEYS MENU_DESC "$last"
        (( REPLY_SEL < 0 )) && break          # q / Echap
        last=$REPLY_SEL
        fn=${MENU_FN[REPLY_SEL]}
        [[ $fn == __quit__ ]] && break
        if [[ $fn == cmd_git ]]; then
            cmd_git                            # sous-menu : gere son propre retour
            continue
        fi
        printf '\n\n'
        ( "$fn" ) || true                      # sous-shell : un exit ne tue pas le menu
        pause_menu && break
    done
    printf '\n'
    log "A bientot."
}

case "${1:-}" in
    --copy)      cmd_copy ;;
    --upgrade)   cmd_upgrade ;;
    --restore)   cmd_restore ;;
    --list)      cmd_list ;;
    --git)       cmd_git ;;
    -h|--help)   usage ;;
    "")          run_menu ;;
    *) die "option inconnue : $1  (voir --help)" ;;
esac
