#!/usr/bin/env bash
#
# update.sh — synchronise les dotfiles entre $HOME et le depot ~/.dotfiles
#
#   update.sh --copy      $HOME  -> depot    (sauvegarde tes configs dans git)
#   update.sh --upgrade   depot  -> $HOME    (deploie ; snapshot auto avant)
#   update.sh --restore   annule le dernier --upgrade (restaure le snapshot)
#   update.sh --list      liste les elements geres et l'etat des snapshots
#   update.sh --resolve   fusion interactive fichier par fichier (diff + choix)
#   update.sh --sync      git pull qui gere tes modifs locales (stash+merge)
#   update.sh --save      snapshote les paquets installes dans le depot
#   update.sh --bootstrap installe TOUT le bureau depuis un Arch minimal :
#                         depots pacman (multilib), paquets, AUR, services,
#                         shell+groupes, clones, themes, puis deploie configs
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

# --- Bootstrap (beta) : listes de paquets + manifeste des depots a cloner.
PKG_REPO="$DOTFILES/packages-repo.txt"   # paquets officiels (pacman)
PKG_AUR="$DOTFILES/packages-aur.txt"     # paquets AUR (yay)
CLONES="$DOTFILES/clones.list"           # depots git : une URL par ligne
CLONES_DIR="$HOME/Documents/Clones"      # tous les depots sont clones ici

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
    sed -n '3,21p' "$0" | sed 's/^#\s\{0,1\}//'
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

# --- Resolver interactif : fusion fichier par fichier ----------------------
#     Pour chaque fichier qui differe entre $HOME et le depot, affiche le diff
#     et demande quelle version garder. Contrairement a --copy / --upgrade
#     (globaux, unidirectionnels), --resolve traite chaque fichier a part : on
#     peut pousser certains fichiers vers le depot et d'autres vers $HOME dans
#     la meme passe. Idéal quand les deux cotes ont diverge ("deux updates").

# apply_one SRC DST : ecrit un fichier unique SRC->DST (cree le parent).
#     Si SRC est absent, "garder ce cote" signifie supprimer DST.
apply_one() {
    local src="$1" dst="$2"
    if [[ -e "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        rsync -a "$src" "$dst"
    else
        rm -f "$dst"
    fi
}

# resolve_scan : remplit le tableau global RES_PAIRS avec "hp|dp|label" pour
#     chaque fichier divergent de tous les ITEMS (fichiers identiques ignores).
resolve_scan() {
    RES_PAIRS=()
    local rel h d sub hp dp
    for rel in "${ITEMS[@]}"; do
        h="$HOME/$rel"; d="$DOTFILES/$rel"
        if [[ -d "$h" || -d "$d" ]]; then
            local -a subs=()
            while IFS= read -r sub; do subs+=("$sub"); done < <(
                { [[ -d "$h" ]] && ( cd "$h" && find . -type f -not -path '*/.git/*' -printf '%P\n' )
                  [[ -d "$d" ]] && ( cd "$d" && find . -type f -not -path '*/.git/*' -printf '%P\n' ) ; } \
                  2>/dev/null | sort -u )
            for sub in "${subs[@]}"; do
                hp="$h/$sub"; dp="$d/$sub"
                [[ -e "$hp" || -e "$dp" ]] || continue
                if [[ -f "$hp" && -f "$dp" ]] && cmp -s "$hp" "$dp"; then continue; fi
                RES_PAIRS+=("$hp|$dp|$rel/$sub")
            done
        else
            hp="$h"; dp="$d"
            [[ -e "$hp" || -e "$dp" ]] || continue
            if [[ -f "$hp" && -f "$dp" ]] && cmp -s "$hp" "$dp"; then continue; fi
            RES_PAIRS+=("$hp|$dp|$rel")
        fi
    done
}

# show_diff HP DP : affiche le diff (depot = -, systeme = +). Gere absence et
#     binaire ; tronque au-dela de 300 lignes pour ne pas noyer le terminal.
show_diff() {
    local hp="$1" dp="$2"
    if [[ ! -e "$hp" ]]; then log "${C_WARN}systeme: absent${C_OFF} — le depot a ce fichier"; return; fi
    if [[ ! -e "$dp" ]]; then log "${C_WARN}depot: absent${C_OFF} — le systeme a ce fichier"; return; fi
    if ! { grep -qI . "$hp" && grep -qI . "$dp"; } 2>/dev/null; then
        log "fichier binaire — diff non affiche."; return
    fi
    log "${C_DIM}(- = depot, + = systeme)${C_OFF}"
    if command -v git >/dev/null; then
        git --no-pager diff --no-index --color=always -- "$dp" "$hp" 2>/dev/null \
            | tail -n +5 | head -n 300 || true
    else
        diff -u --label "depot" --label "systeme" "$dp" "$hp" | head -n 300 || true
    fi
}

cmd_resolve() {
    resolve_scan
    local total=${#RES_PAIRS[@]}
    if (( total == 0 )); then
        log "${C_OK}Rien a resoudre — systeme et depot sont identiques.${C_OFF}"
        return 0
    fi

    # Snapshot de securite (comme --upgrade) : le resolver peut ecrire dans
    # $HOME. Les ecritures cote depot, elles, sont rattrapables via git.
    local stamp snap rel
    stamp="$(date +%Y%m%d-%H%M%S)"
    snap="$BACKUPS/$stamp"
    log "Snapshot de securite  ->  .backups/$stamp  (annulable via --restore)"
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$HOME/$rel" ]]; then
            mirror "$HOME/$rel" "$snap/$rel"
        else
            mkdir -p "$snap"; printf '%s\n' "$rel" >> "$snap/.absents"
        fi
    done
    printf '%s\n' "$stamp" > "$BACKUPS/last"

    printf '\n'; log "$total fichier(s) divergent(s)."
    local i=0 entry hp dp label key applied=0 skipped=0
    for entry in "${RES_PAIRS[@]}"; do
        i=$((i + 1))
        IFS='|' read -r hp dp label <<< "$entry"
        printf '\n  %s[%d/%d] %s%s\n' "$C_TITLE" "$i" "$total" "$label" "$C_OFF"
        show_diff "$hp" "$dp"
        printf '\n  %sGarder : [h] systeme→depot · [d] depot→systeme · [n] passer · [q] quitter%s\n  > ' \
            "$C_KEY" "$C_OFF"
        IFS= read -r key </dev/tty || key=q
        case "$key" in
            h|H) apply_one "$hp" "$dp"; log "${C_OK}✔ systeme -> depot${C_OFF}"; applied=$((applied + 1)) ;;
            d|D) apply_one "$dp" "$hp"; log "${C_OK}✔ depot -> systeme${C_OFF}"; applied=$((applied + 1)) ;;
            q|Q) log "Arret du resolver."; break ;;
            *)   log "passe."; skipped=$((skipped + 1)) ;;
        esac
    done
    printf '\n'
    log "Termine : $applied applique(s), $skipped passe(s)."
    log "Rollback des ecritures cote systeme : update.sh --restore"
    log "Rollback cote depot : git -C \"$DOTFILES\" checkout -- ."
}

# --- Synchronisation git : un "pull" qui gere tes modifs locales -----------
#     Probleme classique : "git pull" refuse car tu as des modifs non commitees
#     (ou des fichiers non-suivis que le commit distant veut ajouter). cmd_sync :
#       1. fait un filet de securite (copie du depot dans .backups),
#       2. degage les fichiers non-suivis que le distant va apporter,
#       3. met tes modifs suivies de cote (git stash),
#       4. recupere le distant (fast-forward ou merge),
#       5. rejoue tes modifs (fusion auto ligne a ligne),
#       6. si un VRAI conflit subsiste, le resout fichier par fichier.

# resolve_git_conflicts : pour chaque fichier en conflit (apres un stash pop),
#     montre le conflit et demande quelle version garder.
#     NB pendant un stash pop : --ours = version DISTANTE, --theirs = tes modifs.
resolve_git_conflicts() {
    local f key
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        printf '\n  %sCONFLIT : %s%s\n' "$C_TITLE" "$f" "$C_OFF"
        git -C "$DOTFILES" --no-pager diff --color=always -- "$f" 2>/dev/null | head -n 200 || true
        printf '\n  %s[l] garder LOCAL (tes modifs) · [r] garder DISTANT · [e] editer · [n] laisser marque%s\n  > ' \
            "$C_KEY" "$C_OFF"
        IFS= read -r key </dev/tty || key=n
        case "$key" in
            l|L) git -C "$DOTFILES" checkout --theirs -- "$f" && git -C "$DOTFILES" add -- "$f"
                 log "${C_OK}local garde.${C_OFF}" ;;
            r|R) git -C "$DOTFILES" checkout --ours   -- "$f" && git -C "$DOTFILES" add -- "$f"
                 log "${C_OK}distant garde.${C_OFF}" ;;
            e|E) "${EDITOR:-nano}" "$DOTFILES/$f" </dev/tty >/dev/tty 2>&1
                 git -C "$DOTFILES" add -- "$f"; log "${C_OK}edite + marque resolu.${C_OFF}" ;;
            *)   log "${C_WARN}laisse en conflit (marqueurs <<< dans le fichier).${C_OFF}" ;;
        esac
    done < <(git -C "$DOTFILES" diff --name-only --diff-filter=U)

    if git -C "$DOTFILES" diff --name-only --diff-filter=U | grep -q .; then
        log "${C_WARN}Des conflits restent a resoudre a la main.${C_OFF}"
    else
        git -C "$DOTFILES" stash drop >/dev/null 2>&1 || true   # entree de stash residuelle
        git -C "$DOTFILES" reset -q HEAD -- . 2>/dev/null || true  # remet en "non commite"
        log "${C_OK}Tous les conflits resolus.${C_OFF}"
    fi
}

cmd_sync() {
    command -v git >/dev/null || die "git introuvable."
    git -C "$DOTFILES" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "$DOTFILES n'est pas un depot git."

    log "Fetch origin..."
    git -C "$DOTFILES" fetch --prune || { log "${C_ERR}fetch echoue.${C_OFF}"; return 1; }

    local up behind ahead
    up=$(git -C "$DOTFILES" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) \
        || { log "${C_ERR}Aucun upstream configure pour cette branche.${C_OFF}"; return 1; }
    read -r behind ahead < <(git -C "$DOTFILES" rev-list --left-right --count '@{u}...HEAD')
    log "Upstream $up  ·  en retard: ${C_WARN}$behind${C_OFF}  ·  en avance: $ahead"

    if (( behind == 0 )); then
        log "${C_OK}Rien a recuperer — deja a jour avec $up.${C_OFF}"
        return 0
    fi

    # 1. Filet de securite : copie du depot (fichiers, hors .git) dans .backups.
    local stamp bk
    stamp="$(date +%Y%m%d-%H%M%S)"
    bk="$BACKUPS/gitsync-$stamp"
    log "Filet de securite  ->  .backups/gitsync-$stamp"
    mkdir -p "$bk"
    rsync -a "${RSYNC_EXCL[@]}" "$DOTFILES/" "$bk/" 2>/dev/null || true

    # 2. Fichiers non-suivis en local que le distant va ajouter : ils bloquent
    #    le merge ("untracked would be overwritten"). On les degage (sauvegardes
    #    dans le filet ci-dessus), le distant fournira sa version.
    local f blockers
    blockers=$(comm -12 \
        <(git -C "$DOTFILES" ls-files --others --exclude-standard | sort) \
        <(git -C "$DOTFILES" diff --name-only HEAD '@{u}' | sort))
    if [[ -n "$blockers" ]]; then
        log "Non-suivis remplaces par la version distante :"
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            log "  degage : $f"; rm -f "$DOTFILES/$f"
        done <<< "$blockers"
    fi

    # 3. Modifs suivies mises de cote.
    local dirty=0
    if ! git -C "$DOTFILES" diff --quiet || ! git -C "$DOTFILES" diff --cached --quiet; then
        dirty=1
        log "Mise de cote de tes modifs suivies (git stash)..."
        git -C "$DOTFILES" stash push -m "sync-$stamp" >/dev/null \
            || { log "${C_ERR}stash echoue.${C_OFF}"; return 1; }
    fi

    # 4. Recuperation : fast-forward si possible, sinon merge.
    log "Recuperation du distant ($behind commit·s)..."
    if ! git -C "$DOTFILES" merge --ff-only '@{u}' >/dev/null 2>&1; then
        git -C "$DOTFILES" merge --no-edit '@{u}' || true
    fi

    # 5. Rejeu des modifs locales (fusion auto ligne a ligne).
    if (( dirty )); then
        log "Rejeu de tes modifs locales..."
        if git -C "$DOTFILES" stash pop >/dev/null 2>&1; then
            log "${C_OK}Fusionne proprement — tes modifs sont conservees.${C_OFF}"
        else
            log "${C_WARN}Conflit(s) reel(s) — resolution fichier par fichier :${C_OFF}"
            resolve_git_conflicts       # 6.
        fi
    fi

    printf '\n'; git -C "$DOTFILES" status -sb | head -n 20
    printf '\n'; log "Filet de securite conserve : .backups/gitsync-$stamp"
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

# --- Bootstrap : "Arch minimal  ->  bureau fonctionnel" en une commande ----
#     --save      snapshote les paquets explicites actuels dans le depot
#     --bootstrap fait TOUT : depots pacman, paquets, AUR, services, shell,
#                 groupes, clones, themes d'icones, puis deploie les configs.
#
# Idempotent : --needed saute ce qui est deja installe, les services deja
# actifs sont ignores, les clones deja presents aussi. Relançable sans risque.
#
# Services systemd actives (ignores si l'unite n'existe pas sur la machine).
SERVICES_SYSTEM=(
    "NetworkManager.service"        # reseau
    "bluetooth.service"             # bluetooth
    "gdm.service"                   # ecran de connexion (alternative : greetd)
    "power-profiles-daemon.service" # profils d'alimentation
    "systemd-timesyncd.service"     # horloge
    "fstrim.timer"                  # TRIM SSD hebdomadaire
)
SERVICES_USER=(
    "pipewire.socket"
    "pipewire-pulse.socket"
    "wireplumber.service"
)
# Groupes utilisateur utiles (ignores s'ils n'existent pas).
USER_GROUPS=(wheel video input storage)

# Recapitulatif de fin : chaque etape s'y ajoute (OK / echec / ignore).
BOOT_REPORT=()
report() { BOOT_REPORT+=("$1"); }

# Lit un fichier de paquets (ignore lignes vides et commentaires) dans un tableau.
read_pkglist() {   # read_pkglist FICHIER  -> remplit le tableau nomme PKGS_OUT
    local file="$1"; PKGS_OUT=()
    [[ -f "$file" ]] || return 1
    local line
    while IFS= read -r line; do
        line="${line%%#*}"                     # retire les commentaires en fin de ligne
        line="${line//[[:space:]]/}"           # trim
        [[ -n "$line" ]] && PKGS_OUT+=("$line")
    done < "$file"
    (( ${#PKGS_OUT[@]} > 0 ))
}

cmd_save() {
    log "Snapshot des paquets explicites  ->  depot"
    if command -v pacman >/dev/null; then
        pacman -Qqen | grep -vE -- '-debug$' > "$PKG_REPO"
        log "officiels : $(wc -l < "$PKG_REPO") paquets  -> $(basename "$PKG_REPO")"
        pacman -Qqm  | grep -vE -- '-debug$' > "$PKG_AUR"
        log "AUR       : $(wc -l < "$PKG_AUR") paquets  -> $(basename "$PKG_AUR")"
    else
        log "pacman introuvable — snapshot ignore."
    fi
    log "Manifeste des clones : $(basename "$CLONES") (a editer a la main)."
}

# --- Etape 1 : depots pacman ------------------------------------------------
# Sur une install Arch minimale, [multilib] est COMMENTE dans pacman.conf. Or
# la liste contient des paquets multilib (steam). `pacman -S` etant atomique,
# un seul nom introuvable fait echouer TOUTE la transaction : niri et tout le
# reste ne s'installent pas. On active donc le depot avant d'installer.
enable_multilib() {
    if grep -q '^\[multilib\]' /etc/pacman.conf; then
        log "[multilib] : deja actif."; return 0
    fi
    log "[multilib] desactive — activation dans /etc/pacman.conf..."
    sudo cp /etc/pacman.conf "/etc/pacman.conf.bak-$(date +%Y%m%d-%H%M%S)"
    # N lit la ligne suivante : on ne dé-commente la paire que si elle est
    # exactement "#[multilib]" + "#Include" ([multilib-testing] n'est pas touche).
    sudo sed -i '/^#\[multilib\]$/{N;s/^#\[multilib\]\n#Include/[multilib]\nInclude/}' \
        /etc/pacman.conf
    if grep -q '^\[multilib\]' /etc/pacman.conf; then
        log "${C_OK}[multilib] active.${C_OFF}"; report "${C_OK}OK${C_OFF}   multilib active"
    else
        log "${C_WARN}Echec : ajoute [multilib] a la main dans /etc/pacman.conf.${C_OFF}"
        report "${C_WARN}!${C_OFF}    multilib NON active (steam echouera)"
    fi
}

# Confort pacman : telechargements paralleles + couleurs (sans effet si deja la).
tune_pacman() {
    grep -q '^ParallelDownloads' /etc/pacman.conf \
        || sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
    grep -q '^Color' /etc/pacman.conf \
        || sudo sed -i 's/^#Color$/Color/' /etc/pacman.conf
}

# --- Etape 2 : installation robuste ----------------------------------------
# pacman/yay sont atomiques : un paquet introuvable (renomme, sorti des depots,
# depot manquant) annule tout le lot. On tente donc le lot d'un coup — rapide
# et avec une seule confirmation — puis, si ca casse, on repasse paquet par
# paquet pour installer tout ce qui est installable et NOMMER ce qui echoue.
FAILED_PKGS=()

# missing_only PKGS... -> remplit MISSING avec les paquets non installes.
#     Relancer --bootstrap ne doit rien refaire d'inutile : ce qui est deja la
#     est saute (les MISES A JOUR, elles, sont faites par le -Syu de l'etape 2,
#     pas ici — plus rapide et une seule confirmation pour tout le systeme).
missing_only() {
    MISSING=(); PRESENT_N=0
    local p
    for p in "$@"; do
        if pacman -Qq -- "$p" >/dev/null 2>&1; then
            PRESENT_N=$((PRESENT_N + 1))
        else
            MISSING+=("$p")
        fi
    done
}

# install_batch DESCRIPTION CMD... -- PKGS...
install_batch() {
    local what="$1"; shift
    local -a cmd=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do cmd+=("$1"); shift; done
    shift                                   # retire le "--"
    local -a want=("$@")
    (( ${#want[@]} )) || return 0

    # Ne garder que ce qui manque : un --bootstrap relance ne reinstalle rien.
    missing_only "${want[@]}"
    local -a pkgs=("${MISSING[@]}")
    log "$what : ${#want[@]} listes · $PRESENT_N deja presents · ${#pkgs[@]} a installer."
    if (( ${#pkgs[@]} == 0 )); then
        log "${C_OK}$what : rien a faire.${C_OFF}"
        report "${C_OK}OK${C_OFF}   $what (deja complet, $PRESENT_N paquets)"
        return 0
    fi

    if "${cmd[@]}" "${pkgs[@]}"; then
        log "${C_OK}$what : lot installe.${C_OFF}"
        report "${C_OK}OK${C_OFF}   $what (${#pkgs[@]} paquets)"
        return 0
    fi

    log "${C_WARN}$what : le lot a echoue — reprise paquet par paquet...${C_OFF}"
    local p ok=0 ko=0
    for p in "${pkgs[@]}"; do
        if "${cmd[@]}" --noconfirm "$p" >/dev/null 2>&1; then
            ok=$((ok + 1))
        else
            ko=$((ko + 1)); FAILED_PKGS+=("$p"); log "  ${C_ERR}echec : $p${C_OFF}"
        fi
    done
    log "$what : $ok installe(s), ${C_ERR}$ko en echec${C_OFF}."
    if (( ko )); then report "${C_WARN}!${C_OFF}    $what : $ko paquet(s) en echec"
    else report "${C_OK}OK${C_OFF}   $what ($ok paquets, reprise unitaire)"; fi
}

# Installe yay depuis l'AUR s'il manque (necessaire sur une install fraiche).
ensure_yay() {
    command -v yay >/dev/null && { log "yay : deja present."; return 0; }
    log "yay absent — installation depuis l'AUR..."
    sudo pacman -S --needed --noconfirm base-devel git || { log "echec base-devel/git."; return 1; }
    local tmp; tmp="$(mktemp -d)"
    if git clone https://aur.archlinux.org/yay.git "$tmp/yay" \
        && ( cd "$tmp/yay" && makepkg -si --noconfirm ); then
        rm -rf "$tmp"; log "yay installe."
    else
        rm -rf "$tmp"; log "echec de l'installation de yay."; return 1
    fi
}

clone_all() {
    [[ -f "$CLONES" ]] || { log "clones.list absent — aucun depot a cloner."; return 0; }
    mkdir -p "$CLONES_DIR"                          # cree Documents/Clones au besoin
    local line url name abs
    while IFS= read -r line; do
        line="${line%%#*}"                          # retire les commentaires
        read -r url name _ <<< "$line"              # url + nom de dossier optionnel
        [[ -z "$url" ]] && continue
        # nom du dossier = 2e champ si fourni, sinon nom du depot (sans .git)
        [[ -z "$name" ]] && { name="${url##*/}"; name="${name%.git}"; }
        abs="$CLONES_DIR/$name"
        if [[ -d "$abs/.git" ]]; then
            log "deja clone : $name"
        else
            log "clone : $url"
            if git clone "$url" "$abs"; then log "  -> Documents/Clones/$name"
            else log "  ECHEC : $url"; fi
        fi
    done < "$CLONES"
}

# --- Etape 4 : themes d'icones clones -> ~/.local/share/icons --------------
#     Un depot comme gruvbox-plus-icon-pack contient un ou plusieurs dossiers
#     de theme (reconnaissables a leur index.theme). On les expose par symlink
#     pour que GTK/nwg-look les voie. ~/.local/ est gitignore : c'est bien le
#     bootstrap qui doit recreer ces liens sur une machine neuve.
link_icon_themes() {
    [[ -d "$CLONES_DIR" ]] || return 0
    local dest="$HOME/.local/share/icons" theme name n=0
    mkdir -p "$dest"
    while IFS= read -r theme; do
        name="$(basename "$theme")"
        if [[ -L "$dest/$name" && -e "$dest/$name" ]]; then
            log "theme deja lie : $name"
        elif [[ -L "$dest/$name" ]]; then
            # lien mort (clone supprime/deplace) : on le refait proprement
            rm -f "$dest/$name"
            ln -s "$theme" "$dest/$name" && { log "${C_OK}relie (lien mort) : $name${C_OFF}"; n=$((n + 1)); }
        elif [[ -e "$dest/$name" ]]; then
            log "${C_WARN}$name existe deja (vrai dossier) — laisse tel quel.${C_OFF}"
        else
            ln -s "$theme" "$dest/$name" && { log "lie : $name"; n=$((n + 1)); }
        fi
    done < <(find "$CLONES_DIR" -mindepth 2 -maxdepth 3 -name index.theme -printf '%h\n' \
             2>/dev/null | sort -u)
    (( n )) && command -v gtk-update-icon-cache >/dev/null \
        && gtk-update-icon-cache -q "$dest" 2>/dev/null || true
    report "${C_OK}OK${C_OFF}   themes d'icones ($n nouveau(x) lien(s))"
}

# --- Etape 5 : services systemd --------------------------------------------
#     Sans ca, une install fraiche demarre sans reseau, sans son et sans ecran
#     de connexion : les paquets sont la mais le bureau ne se lance pas.
enable_services() {
    local unit
    for unit in "${SERVICES_SYSTEM[@]}"; do
        if ! systemctl list-unit-files "$unit" >/dev/null 2>&1 \
           || [[ -z "$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null)" ]]; then
            log "ignore  : $unit (non installe)"; continue
        fi
        # Un gestionnaire de connexion ne doit PAS etre demarre maintenant :
        # `--now` basculerait sur l'ecran de login en plein bootstrap et
        # couperait le terminal avant le deploiement des configs. On l'active
        # pour le prochain demarrage seulement.
        local -a now=(--now)
        case "$unit" in gdm.service|greetd.service|sddm.service|lightdm.service) now=() ;; esac

        case "$(systemctl is-enabled "$unit" 2>/dev/null)" in
            enabled|enabled-runtime|static|indirect|alias)
                log "deja actif : $unit" ;;
            *)  if sudo systemctl enable "${now[@]}" "$unit" >/dev/null 2>&1; then
                    if (( ${#now[@]} )); then log "${C_OK}active : $unit${C_OFF}"
                    else log "${C_OK}active : $unit${C_OFF} ${C_DIM}(au prochain demarrage)${C_OFF}"; fi
                else
                    log "${C_ERR}echec  : $unit${C_OFF}"
                fi ;;
        esac
    done

    # Services utilisateur (audio) : necessite une session utilisateur active.
    if systemctl --user show-environment >/dev/null 2>&1; then
        for unit in "${SERVICES_USER[@]}"; do
            systemctl --user enable --now "$unit" >/dev/null 2>&1 \
                && log "${C_OK}active (user) : $unit${C_OFF}" \
                || log "ignore (user)  : $unit"
        done
    else
        log "${C_WARN}Pas de session systemd --user — services audio a activer apres reconnexion.${C_OFF}"
    fi
    report "${C_OK}OK${C_OFF}   services systemd"
}

# --- Etape 6 : compte utilisateur ------------------------------------------
#     Shell par defaut, groupes, et dossiers XDG (Documents, Images...) — ces
#     derniers sont attendus par nautilus, les captures d'ecran et les clones.
setup_user() {
    # Shell fish
    local fish_bin; fish_bin="$(command -v fish || true)"
    if [[ -n "$fish_bin" ]]; then
        if [[ "$(getent passwd "$USER" | cut -d: -f7)" == "$fish_bin" ]]; then
            log "shell : fish deja par defaut."
        elif sudo chsh -s "$fish_bin" "$USER"; then
            log "${C_OK}shell par defaut -> fish${C_OFF} (effectif a la prochaine session)"
        else
            log "${C_WARN}echec du changement de shell (chsh -s $fish_bin $USER).${C_OFF}"
        fi
    fi

    # Groupes
    local g added=()
    for g in "${USER_GROUPS[@]}"; do
        getent group "$g" >/dev/null 2>&1 || continue
        id -nG "$USER" | tr ' ' '\n' | grep -qxF "$g" && continue
        sudo usermod -aG "$g" "$USER" && added+=("$g")
    done
    if (( ${#added[@]} )); then
        log "${C_OK}groupes ajoutes : ${added[*]}${C_OFF} (effectif a la reconnexion)"
    else
        log "groupes : rien a ajouter."
    fi

    # Dossiers XDG
    command -v xdg-user-dirs-update >/dev/null && xdg-user-dirs-update || true
    mkdir -p "$CLONES_DIR"
    report "${C_OK}OK${C_OFF}   compte utilisateur (shell, groupes, dossiers XDG)"
}

step() { printf '\n  %s── %s %s%s\n' "$C_TITLE" "$1" \
         "$(printf '%.0s─' $(seq 1 $((40 - ${#1} > 0 ? 40 - ${#1} : 1))))" "$C_OFF"; }

cmd_bootstrap() {
    command -v pacman >/dev/null || die "pacman introuvable — ce bootstrap vise Arch Linux."
    BOOT_REPORT=(); FAILED_PKGS=()

    printf '\n  %sBOOTSTRAP%s — Arch minimal  ->  bureau niri fonctionnel.\n' "$C_TITLE" "$C_OFF"
    log "Depot : $DOTFILES"
    printf '\n  Etapes : depots pacman · paquets officiels · yay · paquets AUR ·\n'
    printf '           services · shell+groupes · clones git · themes · configs\n'
    log "${C_DIM}Relançable sans risque : tout ce qui est deja en place est saute.${C_OFF}"

    if [[ -t 0 ]]; then
        printf '\n  %sLancer le bootstrap ? [o/N]%s ' "$C_KEY" "$C_OFF"
        local ans; IFS= read -r ans </dev/tty || ans=n
        [[ $ans == [oOyY] ]] || { printf '\n'; log "Annule."; return 0; }
    fi

    # Un seul mot de passe pour toute la session (les etapes s'enchainent).
    sudo -v || { log "${C_ERR}sudo requis.${C_OFF}"; return 1; }

    # 1. Depots + mise a jour du systeme. enable_multilib DOIT passer avant
    #    l'installation : sinon les paquets multilib (steam) sont introuvables
    #    et pacman, atomique, annule tout le lot — niri compris.
    step "1/9  Depots pacman"
    enable_multilib
    tune_pacman
    log "Mise a jour du systeme (pacman -Syu)..."
    sudo pacman -Syu --needed --noconfirm archlinux-keyring \
        || log "${C_WARN}keyring : echec (on continue).${C_OFF}"
    sudo pacman -Syu || log "${C_WARN}-Syu : echec (on continue).${C_OFF}"

    # 2. Paquets officiels. Passes en arguments (pas via stdin) pour que pacman
    #    affiche normalement ses confirmations.
    step "2/9  Paquets officiels"
    if read_pkglist "$PKG_REPO"; then
        install_batch "Paquets officiels" sudo pacman -S --needed -- "${PKGS_OUT[@]}"
    else
        log "packages-repo.txt vide/absent (lance --save d'abord)."
        report "${C_WARN}!${C_OFF}    packages-repo.txt absent"
    fi

    # 3. AUR helper
    step "3/9  yay (AUR)"
    if ensure_yay; then
        report "${C_OK}OK${C_OFF}   yay"
    else
        report "${C_ERR}KO${C_OFF}   yay — paquets AUR sautes"
    fi

    # 4. Paquets AUR
    step "4/9  Paquets AUR"
    if ! command -v yay >/dev/null; then
        log "yay absent — etape sautee."
    elif read_pkglist "$PKG_AUR"; then
        install_batch "Paquets AUR" yay -S --needed -- "${PKGS_OUT[@]}"
    else
        log "packages-aur.txt vide/absent."
    fi

    # 5. Services
    step "5/9  Services systemd"
    enable_services

    # 6. Compte utilisateur
    step "6/9  Compte utilisateur"
    setup_user

    # 7. Depots git
    step "7/9  Depots git"
    clone_all
    report "${C_OK}OK${C_OFF}   clones git"

    # 8. Themes d'icones (dependent des clones)
    step "8/9  Themes d'icones"
    link_icon_themes

    # 9. Deploiement des configs : c'est ce qui rend le bureau *le tien*.
    #    cmd_upgrade fait son propre snapshot, donc annulable via --restore.
    step "9/9  Configs (depot -> \$HOME)"
    cmd_upgrade
    report "${C_OK}OK${C_OFF}   configs deployees"

    # --- Recapitulatif
    printf '\n  %s╭─ Recapitulatif ──────────────────────────────╮%s\n' "$C_TITLE" "$C_OFF"
    local line
    for line in "${BOOT_REPORT[@]}"; do printf '  %b\n' "$line"; done
    printf '  %s╰──────────────────────────────────────────────╯%s\n' "$C_TITLE" "$C_OFF"

    if (( ${#FAILED_PKGS[@]} )); then
        printf '\n'; log "${C_ERR}Paquets en echec (${#FAILED_PKGS[@]}) :${C_OFF}"
        log "  ${FAILED_PKGS[*]}"
        log "${C_DIM}Souvent : paquet renomme/retire des depots. Corrige la liste,${C_OFF}"
        log "${C_DIM}puis relance --bootstrap (il ne refera que ce qui manque).${C_OFF}"
    fi

    printf '\n'
    log "${C_OK}Bootstrap termine.${C_OFF} Il reste a :"
    log "  - redemarrer (shell fish, groupes et gdm/niri prennent effet)"
    log "  - a la connexion, choisir la session ${C_KEY}niri${C_OFF}"
    log "  - annuler le deploiement des configs : update.sh --restore"
}

# --- Menu principal ---------------------------------------------------------
MENU_KEYS=("copy" "upgrade" "restore" "list" "resolve" "sync" "save" "bootstrap" "git" "Quitter")
MENU_FN=("cmd_copy" "cmd_upgrade" "cmd_restore" "cmd_list" "cmd_resolve" "cmd_sync" "cmd_save" "cmd_bootstrap" "cmd_git" "__quit__")
MENU_DESC=(
    "Sauvegarder   \$HOME  ->  depot git"
    "Deployer      depot git  ->  \$HOME   (snapshot avant)"
    "Restaurer     annuler le dernier --upgrade (rollback)"
    "Etat          lister les configs et le dernier snapshot"
    "Resoudre      fusion fichier par fichier (diff + choix)"
    "Sync          git pull en gerant tes modifs locales (stash+merge)"
    "Save pkgs     snapshot des paquets installes -> depot"
    "Bootstrap     tout installer : Arch minimal -> bureau fonctionnel"
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
    --resolve)   cmd_resolve ;;
    --sync)      cmd_sync ;;
    --save)      cmd_save ;;
    --bootstrap) cmd_bootstrap ;;
    --git)       cmd_git ;;
    -h|--help)   usage ;;
    "")          run_menu ;;
    *) die "option inconnue : $1  (voir --help)" ;;
esac
