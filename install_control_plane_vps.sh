#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash install_control_plane_vps.sh ...)"
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-/opt/bbauto-control-plane-installer}"
FORCE_RESET="${FORCE_RESET:-false}"
INSTALLER_REPO="${INSTALLER_REPO:-https://github.com/wd9337812/bbexchange-installer}"
INSTALLER_REF="${INSTALLER_REF:-main}"

usage() {
  cat <<EOF
Usage:
  bash install_control_plane_vps.sh [options]

Options:
  --target-dir <path>    Installer unpack dir (default: ${TARGET_DIR})
  --repo <url>           Public installer repo url (default: ${INSTALLER_REPO})
  --ref <name>           Repo branch/tag/commit (default: ${INSTALLER_REF})
  --force-reset          Remove existing target dir before copy
  -h, --help             Show help

Remaining args will be passed to scripts/bootstrap_control_plane_vps_image.sh.
EOF
}

PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir) TARGET_DIR="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
    --repo) INSTALLER_REPO="$2"; shift 2 ;;
    --ref) INSTALLER_REF="$2"; shift 2 ;;
    --force-reset) FORCE_RESET="true"; PASS_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

apt-get update -y
apt-get install -y curl ca-certificates tar

if [[ -d "${TARGET_DIR}" ]]; then
  if [[ "${FORCE_RESET}" == "true" ]]; then
    rm -rf "${TARGET_DIR}"
  fi
fi

mkdir -p "${TARGET_DIR}"
TMP_ARCHIVE="/tmp/bbexchange-installer-${INSTALLER_REF}.tar.gz"
TMP_UNPACK_DIR="/tmp/bbexchange-installer-${INSTALLER_REF}-src"
rm -rf "${TMP_UNPACK_DIR}"
curl -fsSL -o "${TMP_ARCHIVE}" "${INSTALLER_REPO}/archive/refs/heads/${INSTALLER_REF}.tar.gz" || \
  curl -fsSL -o "${TMP_ARCHIVE}" "${INSTALLER_REPO}/archive/refs/tags/${INSTALLER_REF}.tar.gz"
mkdir -p "${TMP_UNPACK_DIR}"
tar -xzf "${TMP_ARCHIVE}" -C "${TMP_UNPACK_DIR}"
SRC_DIR="$(find "${TMP_UNPACK_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "${SRC_DIR}" || ! -f "${SRC_DIR}/scripts/bootstrap_control_plane_vps_image.sh" ]]; then
  echo "Installer bundle is invalid: missing scripts/bootstrap_control_plane_vps_image.sh"
  exit 1
fi
cp -a "${SRC_DIR}/." "${TARGET_DIR}/"

cd "${TARGET_DIR}"
sed -i 's/\r$//' scripts/bootstrap_control_plane_vps_image.sh
bash scripts/bootstrap_control_plane_vps_image.sh "${PASS_ARGS[@]}"
