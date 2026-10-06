# bbexchange-installer

Public one-command installer repository for BBexchange/BBAuto deployments.

## 1) User instance install (stable channel)

```bash
curl -fsSL https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_vps.sh \
| sed '1s/^\xEF\xBB\xBF//' \
| sudo bash
```

## 2) User instance update (stable channel)

In user VPS install directory:

```bash
cd /opt/brandbidding
sudo bash scripts/update_image.sh
```

## Optional deployment options

```bash
curl -fsSL -o /tmp/install_vps.sh https://raw.githubusercontent.com/wd9337812/bbexchange-installer/main/install_vps.sh
sudo bash /tmp/install_vps.sh --ssl auto --domain example.com
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

## 5) Google Ads API v25 migration

The stable release upgrades the system REST API, API/Worker configuration and generated Google Ads Scripts to v25. Existing configuration below v25 is upgraded automatically; the updater backs up a changed old env value and preserves other settings. No Google account re-link is required solely for the version update.

If using MCC script mode, copy the new script from System Settings → Google Ads → Google Ads Script, replace the script already saved in Google Ads and keep its existing schedule. Server updates cannot replace scripts saved in Google's UI; do not create a duplicate schedule. The system's Google Ads settings and MCP `get_google_ads_api_runtime` show the effective version. Refresh the Agent tool list and read `get_agent_guide` again after upgrading.
