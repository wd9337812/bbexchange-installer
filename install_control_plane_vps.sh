#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (use: sudo bash install_control_plane_vps.sh ...)"
  exit 1
fi

REPO_URL="${REPO_URL:-https://github.com/wd9337812/BBexchange.git}"
BRANCH="${BRANCH:-codex/phase1-task-crud}"
TARGET_DIR="${TARGET_DIR:-/opt/bbauto-control-plane-installer}"
FORCE_RESET="${FORCE_RESET:-false}"

usage() {
  cat <<EOF
Usage:
  bash install_control_plane_vps.sh [options]

Options:
  --repo-url <url>       Git repo url (default: ${REPO_URL})
  --branch <name>        Git branch (default: ${BRANCH})
  --target-dir <path>    Installer checkout dir (default: ${TARGET_DIR})
  --force-reset          Remove existing target dir before clone
  -h, --help             Show help

Remaining args will be passed to scripts/bootstrap_control_plane_vps_image.sh.
EOF
}

PASS_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url) REPO_URL="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
    --branch) BRANCH="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
    --target-dir) TARGET_DIR="$2"; PASS_ARGS+=("$1" "$2"); shift 2 ;;
    --force-reset) FORCE_RESET="true"; PASS_ARGS+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) PASS_ARGS+=("$1"); shift ;;
  esac
done

apt-get update -y
apt-get install -y git curl ca-certificates

if [[ -d "${TARGET_DIR}" ]]; then
  if [[ "${FORCE_RESET}" == "true" ]]; then
    rm -rf "${TARGET_DIR}"
  fi
fi

if [[ ! -d "${TARGET_DIR}" ]]; then
  git clone -b "${BRANCH}" "${REPO_URL}" "${TARGET_DIR}"
else
  cd "${TARGET_DIR}"
  git remote set-url origin "${REPO_URL}"
  git fetch --all --prune
  git checkout "${BRANCH}"
  git reset --hard "origin/${BRANCH}"
fi

cd "${TARGET_DIR}"
sed -i 's/\r$//' scripts/bootstrap_control_plane_vps_image.sh
bash scripts/bootstrap_control_plane_vps_image.sh "${PASS_ARGS[@]}"
