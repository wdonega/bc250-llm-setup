#!/usr/bin/env bash
# 30-ram-gtt.sh — raise the TTM page limits so the APU can address most of RAM.
#
# Idempotent. Run with sudo. Requires a reboot to take effect.
#
# The BC-250 has no dedicated VRAM worth speaking of: with the BIOS set to a
# 1 GB carve-out, everything the model needs comes out of system RAM through
# GTT. TTM caps how many pages it will hand out, and the default is roughly
# half of RAM — which silently puts a ceiling on model size well below what
# the board can actually hold.
#
#   ttm.pages_limit    hard cap on pages TTM will allocate
#   ttm.page_pool_size size of the pool it keeps around
#
# 3670016 pages x 4 KiB = 14 GiB. On a 16 GB board that leaves ~2 GB for the
# OS, which is the headroom this value was picked for — raise it only if you
# are prepared to watch for the OOM killer under sustained load.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_root

GRUB_FILE=/etc/default/grub
TTM_PAGES=3670016
PARAMS=("ttm.pages_limit=${TTM_PAGES}" "ttm.page_pool_size=${TTM_PAGES}")

[[ -f "$GRUB_FILE" ]] || fail "${GRUB_FILE} not found — is this a GRUB system?"

# Guard rail: the original one-liner was a plain sed that only matched an
# EMPTY GRUB_CMDLINE_LINUX_DEFAULT="". On a host that already had kernel
# params it matched nothing and exited 0, so you rebooted into an unchanged
# config believing it had worked. Parse the current value instead.
OCCURRENCES=$(grep -cE '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)
if [[ "$OCCURRENCES" -gt 1 ]]; then
  fail "${GRUB_FILE} has ${OCCURRENCES} GRUB_CMDLINE_LINUX_DEFAULT lines. \
Editing it automatically would clobber all of them — clean it up by hand first."
fi

CURRENT=""
if [[ "$OCCURRENCES" -eq 1 ]]; then
  CURRENT=$(sed -nE 's/^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="?([^"]*)"?[[:space:]]*$/\1/p' "$GRUB_FILE")
fi
info "Current kernel cmdline: \"${CURRENT}\""

# Drop any ttm.* params we manage, keep everything else, then append ours.
# This is what makes re-runs and value changes safe instead of cumulative.
KEPT=""
read -ra CURRENT_TOKENS <<< "$CURRENT"
for token in "${CURRENT_TOKENS[@]}"; do
  case "$token" in
    ttm.pages_limit=*|ttm.page_pool_size=*) ;;
    "") ;;
    *) KEPT="${KEPT}${KEPT:+ }${token}" ;;
  esac
done
NEW="${KEPT}${KEPT:+ }${PARAMS[*]}"

if [[ "$CURRENT" == "$NEW" ]]; then
  ok "GRUB already has the right TTM limits — nothing to change"
else
  BAK=$(backup_file "$GRUB_FILE")
  info "Backed up to ${BAK}"
  if [[ "$OCCURRENCES" -eq 1 ]]; then
    sed -i -E "s|^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=.*$|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW}\"|" "$GRUB_FILE"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW}\"" >> "$GRUB_FILE"
  fi
  ok "new cmdline: \"${NEW}\""

  info "Regenerating the GRUB config"
  if have update-grub; then
    update-grub
  else
    grub-mkconfig -o /boot/grub/grub.cfg
  fi
fi

echo
grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"

# Already live? Then the reboot already happened and we can verify for real.
if grep -q "ttm.pages_limit=${TTM_PAGES}" /proc/cmdline; then
  if GPU_PATH="$(gpu_device_path)"; then
    GTT_MIB=$(( $(cat "${GPU_PATH}/mem_info_gtt_total") / 1024 / 1024 ))
    ok "limits are live — GTT total: ${GTT_MIB} MiB"
  else
    ok "limits are live on the running kernel"
  fi
else
  reboot_required \
    "cat /proc/cmdline                                    # ttm.* present" \
    "cat /sys/class/drm/card*/device/mem_info_gtt_total   # ~14 GiB"
fi
