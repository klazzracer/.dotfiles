#!/usr/bin/env bash
# install-cursor.sh — installe le theme de curseur commun (Material Bibata, variante Sage)
# depuis l'archive gardee sur le Synology (trop lourde pour git : ~30 Mo par variante).
#
#   scripts/install-cursor.sh            installe Bibata-Material-Sage
#   scripts/install-cursor.sh Teal       installe une autre variante du meme pack
#
# Appele aussi par update.sh --bootstrap. Les reglages qui pointent vers le theme
# (gtk-*/settings.ini, .gtkrc-2.0, niri cursor{}) sont dans le depot ; gsettings et
# ~/.icons/default sont poses ici pour les applis qui n'ecoutent que ca.
set -euo pipefail

VARIANT="${1:-Sage}"
THEME="Bibata-Material-$VARIANT"
ARCHIVE="${CURSOR_ARCHIVE:-$HOME/SynologyDrive/Themes/bibata-material-dark-v1.5.0.tar.gz}"
DEST="$HOME/.local/share/icons/$THEME"

if [[ -d "$DEST/cursors" ]]; then
    echo "deja installe : $DEST"
else
    [[ -f "$ARCHIVE" ]] || { echo "archive introuvable : $ARCHIVE (Synology pas encore synchronise ?)" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    tar xzf "$ARCHIVE" -C "$tmp"
    src="$(find "$tmp" -maxdepth 2 -type d -name "$THEME" | head -1)"
    [[ -n "$src" ]] || { echo "variante $THEME absente de l'archive" >&2; exit 1; }
    mkdir -p "$DEST"
    cp -a "$src/index.theme" "$src/cursors" "$DEST/"
    [[ -d "$src/cursors_scalable" ]] && cp -a "$src/cursors_scalable" "$DEST/"
    echo "installe : $DEST"
fi

command -v gsettings >/dev/null && {
    gsettings set org.gnome.desktop.interface cursor-theme "$THEME"
    gsettings set org.gnome.desktop.interface cursor-size 24
}
mkdir -p "$HOME/.icons/default"
printf '[Icon Theme]\nName=Default\nComment=Default Cursor Theme\nInherits=%s\n' "$THEME" > "$HOME/.icons/default/index.theme"
echo "curseur actif : $THEME (reconnexion necessaire pour les applis deja ouvertes)"
