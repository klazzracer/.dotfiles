#!/usr/bin/env bash
#
# update.sh — synchronise les dotfiles entre $HOME et le depot ~/.dotfiles
#
#   update.sh --copy      $HOME  -> depot    (sauvegarde tes configs dans git)
#   update.sh --paste     depot  -> $HOME    (deploie ; snapshot auto avant)
#   update.sh --restore   annule le dernier --paste (restaure le snapshot)
#   update.sh --list      liste les elements geres et l'etat des snapshots
#   update.sh --help
#
# Le rollback : avant chaque --paste, l'etat courant est copie dans
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
)

log() { printf '  %s\n' "$*"; }
die() { printf 'update.sh: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '3,13p' "$0" | sed 's/^#\s\{0,1\}//'
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
            log "sauve   : $rel"; ((n++)) || true
        else
            log "absent  : $rel (ignore)"
        fi
    done
    log "$n element(s) copie(s). Pense a committer :"
    log "  git -C \"$DOTFILES\" add -A && git -C \"$DOTFILES\" commit -m 'update dotfiles'"
}

cmd_paste() {
    local stamp snap rel
    stamp="$(date +%Y%m%d-%H%M%S)"
    snap="$BACKUPS/$stamp"

    log "Snapshot des configs actuelles  ->  .backups/$stamp"
    for rel in "${ITEMS[@]}"; do
        if [[ -e "$HOME/$rel" ]]; then
            mirror "$HOME/$rel" "$snap/$rel"
        else
            # marque l'absence : --restore devra re-supprimer si --paste le cree
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
    [[ -f "$BACKUPS/last" ]] || die "aucun snapshot — fais d'abord un --paste"
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
            # cet element n'existait pas avant le --paste : on le retire
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

case "${1:-}" in
    --copy)    cmd_copy ;;
    --paste)   cmd_paste ;;
    --restore) cmd_restore ;;
    --list)    cmd_list ;;
    -h|--help|"") usage ;;
    *) die "option inconnue : $1  (voir --help)" ;;
esac
