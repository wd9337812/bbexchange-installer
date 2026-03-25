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
sudo bash scripts/update_image.sh latest
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

The script is self-contained in this public repo and does not require cloning the private app repository.

## 4) Control plane update (website/admin)

```bash
cd /opt/bbauto-control-plane
sudo bash scripts/update_control_plane_site.sh
```
