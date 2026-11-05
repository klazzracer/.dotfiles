# .dotfiles
dotfiles for my linux config

## Themes (laptop thinkarch + tower ArchSam)

- Couleurs : noctalia, palette communautaire "Gruvbox Material Medium", templates niri/gtk3/gtk4/kitty
  (`noctalia msg templates-apply` pour regenerer).
- GTK : adw-gtk3-dark (paquet adw-gtk-theme) + gtk.css qui importe noctalia.css.
- Icones : Gruvbox-Plus-Dark (clone via clones.list, lie par update.sh).
- Curseur : Material Bibata, variante Sage. Archive dans ~/SynologyDrive/Themes/, installation par
  `scripts/install-cursor.sh` (aussi appele par --bootstrap).
- kitty : theme noctalia + JetBrainsMono Nerd Font ; fish : conf.d/theme-gruvbox-material.fish ; vim : gruvbox-material.
- Les fichiers propres a une machine (noctalia settings.toml) sont dans hosts/<nom-machine>/.

