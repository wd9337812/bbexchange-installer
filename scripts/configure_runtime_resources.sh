#!/usr/bin/env bash
# Shared by the public image installer and updater. Never reset explicit settings.
set -euo pipefail
runtime_resource_recommend() {
  local kib="$1" cpus="$2" n=1 cpu_cap
  if [[ ! "$kib" =~ ^[0-9]+$ || ! "$cpus" =~ ^[0-9]+([.][0-9]+)?$ ]]; then printf '2\n'; return; fi
  if (( kib >= 29360128 )); then n=12
  elif (( kib >= 14680064 )); then n=8
  elif (( kib >= 7340032 )); then n=6
  elif (( kib >= 3670016 )); then n=2; fi
  cpu_cap="$(awk -v c="$cpus" 'BEGIN { n=int(c*2); print n<1?1:n }')"
  if (( n > cpu_cap )); then n="$cpu_cap"; fi
  printf '%s\n' "$n"
}
runtime_resource_detect() {
  local proc_root="${RUNTIME_PROC_ROOT:-/proc}" cgroup_root="${RUNTIME_CGROUP_ROOT:-/sys/fs/cgroup}"
  local kib cpus relative dir value quota period limited first last
  kib="$(awk '/^MemTotal:/ {print $2}' "$proc_root/meminfo" 2>/dev/null || true)"
  cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
  relative="$(awk -F: '$1==0 {print $3}' "$proc_root/self/cgroup" 2>/dev/null || true)"
  [[ "$relative" == /* && "$relative" != *'..'* ]] || relative='/'
  dir="$cgroup_root$relative"
  [[ -d "$dir" ]] || dir="$cgroup_root"
  while [[ "$dir" == "$cgroup_root" || "$dir" == "$cgroup_root/"* ]]; do
    value="$(cat "$dir/memory.max" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]{1,16}$ ]] && (( value > 0 )); then
      limited=$((value / 1024))
      if [[ ! "$kib" =~ ^[0-9]+$ ]] || (( limited < kib )); then kib="$limited"; fi
    fi
    quota='' period=''
    read -r quota period 2>/dev/null < "$dir/cpu.max" || true
    if [[ "${quota:-}" =~ ^[0-9]+$ && "${period:-}" =~ ^[0-9]+$ ]] && (( period > 0 )); then
      cpus="$(awk -v q="$quota" -v p="$period" -v c="$cpus" 'BEGIN {l=q/p;print l<c?l:c}')"
    fi
    value="$(cat "$dir/cpuset.cpus.effective" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9,-]+$ ]]; then
      limited="$(awk -F, '{s=0;for(i=1;i<=NF;i++){split($i,a,"-");s+=a[2]?a[2]-a[1]+1:1}print s}' <<< "$value")"
      cpus="$(awk -v l="$limited" -v c="$cpus" 'BEGIN {print l<c?l:c}')"
    fi
    [[ "$dir" == "$cgroup_root" ]] && break
    dir="${dir%/*}"
  done
  # Legacy cgroup v1 installations retain their own memory and CPU ceilings.
  value="$(cat "$cgroup_root/memory/memory.limit_in_bytes" 2>/dev/null || true)"
  if [[ "$value" =~ ^[0-9]{1,16}$ ]] && (( value > 0 )); then
    limited=$((value / 1024)); if [[ ! "$kib" =~ ^[0-9]+$ ]] || (( limited < kib )); then kib="$limited"; fi
  fi
  quota="$(cat "$cgroup_root/cpu/cpu.cfs_quota_us" 2>/dev/null || true)"
  period="$(cat "$cgroup_root/cpu/cpu.cfs_period_us" 2>/dev/null || true)"
  if [[ "$quota" =~ ^[0-9]+$ && "$period" =~ ^[0-9]+$ ]] && (( quota > 0 && period > 0 )); then
    cpus="$(awk -v q="$quota" -v p="$period" -v c="$cpus" 'BEGIN {l=q/p;print l<c?l:c}')"
  fi
  printf '%s %s\n' "${kib:-unknown}" "${cpus:-unknown}"
}
configure_runtime_resources() {
  local env_file="${1:-.env.prod}" mode explicit kib cpus n backup
  [[ -f "$env_file" ]] || { echo 'Resource configuration: environment file missing' >&2; return 1; }
  mode="$(sed -n 's/^BROWSER_CONCURRENCY_MODE=//p' "$env_file" | head -n 1 | tr -d '\r')"
  explicit="$(sed -n 's/^BROWSER_POOL_SIZE=//p' "$env_file" | head -n 1 | tr -d '\r')"
  if [[ "$mode" != 'auto' && -n "$explicit" ]]; then
    echo "Resource configuration: preserving explicit browser limit ${explicit}."
    return
  fi
  read -r kib cpus <<< "$(runtime_resource_detect)"
  n="$(runtime_resource_recommend "$kib" "$cpus")"
  backup="${env_file}.before-runtime-resources.$(date -u +%Y%m%dT%H%M%SZ).bak"
  cp -p -- "$env_file" "$backup"
  for item in "BROWSER_CONCURRENCY_MODE=auto" "BROWSER_POOL_SIZE=$n" 'BROWSER_RESOURCE_POLICY_VERSION=2026-10-10.1'; do
    local key="${item%%=*}"
    if grep -q "^${key}=" "$env_file"; then sed -i "s|^${key}=.*|${item}|" "$env_file"
    else printf '%s\n' "$item" >> "$env_file"; fi
  done
  echo "Resource configuration: auto browser recommendation ${n}; runtime applies CPU/container limits."
}
capture_runtime_resource_env() {
  local env_file="$1" backup="$2"
  (umask 077; grep -E '^(BROWSER_CONCURRENCY_MODE|BROWSER_POOL_SIZE|BROWSER_RESOURCE_POLICY_VERSION)=' "$env_file" > "$backup" || true)
}
restore_runtime_resource_env() {
  local env_file="$1" backup="$2"
  [[ -f "$env_file" && -f "$backup" ]] || return 1
  sed -i -e '/^BROWSER_CONCURRENCY_MODE=/d' -e '/^BROWSER_POOL_SIZE=/d' -e '/^BROWSER_RESOURCE_POLICY_VERSION=/d' "$env_file"
  grep -E '^(BROWSER_CONCURRENCY_MODE|BROWSER_POOL_SIZE|BROWSER_RESOURCE_POLICY_VERSION)=' "$backup" >> "$env_file" || true
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then configure_runtime_resources "${1:-.env.prod}"; fi
