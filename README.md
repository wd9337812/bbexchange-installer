# bbexchange-installer

Public one-command installer repository for BBexchange/BBAuto deployments.

## 1) User instance install (interactive, latest)

```bash
curl -fsSL -o /tmp/install_vps.sh https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_vps.sh
sudo bash /tmp/install_vps.sh
```

## 2) User instance update (keep original latest behavior)

In user VPS install directory:

```bash
cd /opt/brandbidding
sudo docker compose --env-file .env.prod -f deploy/docker-compose.image.yml pull
sudo docker compose --env-file .env.prod -f deploy/docker-compose.image.yml up -d
```

## Optional deployment options

```bash
sudo bash /tmp/install_vps.sh --image-tag latest --ssl auto --domain example.com
```

Default image namespace: `ghcr.io/wd9337812`.

## 3) Control plane install (operator only)

```bash
curl -fsSL -o /tmp/install_control_plane_vps.sh https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_control_plane_vps.sh
sudo bash /tmp/install_control_plane_vps.sh
```

`install_control_plane_vps.sh` clones the app repo branch and runs `scripts/bootstrap_control_plane_vps_image.sh`.
