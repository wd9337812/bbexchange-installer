# bbexchange-installer

Public one-command installer for BBexchange image deployment.

## Install on a clean Ubuntu VPS

```bash
curl -fsSL -o /tmp/install_vps.sh https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_vps.sh
sudo bash /tmp/install_vps.sh
```

## Optional registry auth (for private images)

```bash
sudo bash /tmp/install_vps.sh --registry-user <user> --registry-token <token>
```

Default image namespace: `docker.io/wd933781`.
