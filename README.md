# bbexchange-installer

Public one-command installer for BBexchange image deployment.

## Install on a clean Ubuntu VPS

```bash
curl -fsSL -o /tmp/install_vps.sh https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_vps.sh
sudo bash /tmp/install_vps.sh
```

## Private GHCR images

```bash
sudo bash /tmp/install_vps.sh --ghcr-user <github_user> --ghcr-token <github_pat_with_read_packages>
```
