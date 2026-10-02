# etc

Copies de fichiers système (`/etc`), même arborescence.

| Fichier | Rôle |
|---|---|
| `udev/rules.d/70-epomaker.rules` | Accès WebHID au clavier Epomaker TH80 V2 PRO (`0c45:800b`) pour Epomaker Hub dans le navigateur |

Installation :

```sh
sudo cp etc/udev/rules.d/*.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```
