#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash install_control_plane_vps.sh ...)"
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-/opt/bbauto-control-plane-installer}"
FORCE_RESET="${FORCE_RESET:-false}"

usage() {
  cat <<EOF
Usage:
  bash install_control_plane_vps.sh [options]

Options:
  --target-dir <path>    Installer unpack dir (default: ${TARGET_DIR})
  --force-reset          Remove existing target dir before copy
  -h, --help             Show help

Remaining args will be passed to scripts/bootstrap_control_plane_vps_image.sh.
EOF
}

PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir) TARGET_DIR="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
    --force-reset) FORCE_RESET="true"; PASS_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

apt-get update -y
apt-get install -y curl ca-certificates rsync

if [[ -d "${TARGET_DIR}" ]]; then
  if [[ "${FORCE_RESET}" == "true" ]]; then
    rm -rf "${TARGET_DIR}"
  fi
fi

mkdir -p "${TARGET_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rsync -a --delete \
  --exclude '.git' \
  --exclude '.github' \
  "${SCRIPT_DIR}/" "${TARGET_DIR}/"

cd "${TARGET_DIR}"
sed -i 's/\r$//' scripts/bootstrap_control_plane_vps_image.sh
bash scripts/bootstrap_control_plane_vps_image.sh "${PASS_ARGS[@]}"
