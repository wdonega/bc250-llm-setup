#!/usr/bin/env bash
# 60-unlock-40cu.sh — enable all 40 CUs on the APU.
#
# Run with sudo. Requires a reboot. Read the warnings before running it.
#
#   --map-only   print the CU harvest map and exit, changing nothing
#
# The BC-250 ships with 24 of its 40 CUs fused off in the amdgpu driver's
# view. This patches the driver to expose all 40. Upstream tooling lives in
# https://github.com/wdonega/bc250-40cu-unlock — this script only wraps it
# with the checks that are easy to skip when doing it by hand.
#
# THREE THINGS THAT BITE:
#
#  1. A kernel upgrade silently reverts this — the patched module is built
#     against the running kernel. Re-run `build` after upgrades, or pin the
#     kernel. Nothing warns you; you just quietly get 24 CUs back.
#
#  2. Power draw goes up a lot (~125 W vs ~95 W at the same clock), so the
#     thermal ceiling you found with 24 CUs is no longer valid. Re-tune
#     afterwards — that is not optional, it is step 9 of the README.
#
#  3. If the harvest map is scattered rather than contiguous, some of those
#     CUs may be genuinely defective silicon. Enabling them anyway gets you
#     hangs and corrupt output, not free performance.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_root

REPO_DIR="${UNLOCK_DIR:-/opt/bc250-40cu-unlock}"
REPO_URL=https://github.com/wdonega/bc250-40cu-unlock.git
MAP_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map-only) MAP_ONLY=1 ;;
    *) fail "unknown option: $1 (accepts --map-only)" ;;
  esac
  shift
done

# --- guard rails -----------------------------------------------------------

require_gpu_device_path > /dev/null
ok "BC-250 APU confirmed at $(gpu_device_path)"

# Already done? Then this is a post-kernel-upgrade rebuild, which is fine, but
# say so rather than looking like a fresh install.
if modinfo amdgpu 2>/dev/null | grep -qi bc250; then
  info "the running amdgpu module already carries the bc250 parameter"
fi

# --- dependencies ----------------------------------------------------------

if [[ "$MAP_ONLY" -eq 0 ]]; then
  info "Installing kernel build dependencies for $(uname -r)"
  # linux-source-<major.minor.patch> is what the upstream build expects; the
  # name drops the ABI/flavour suffix that uname -r carries.
  apt-get update -qq
  apt-get install -y gcc make zstd binutils pciutils \
    "linux-headers-$(uname -r)" \
    "linux-source-$(uname -r | cut -d- -f1)"
fi

# --- source ----------------------------------------------------------------

if [[ -d "$REPO_DIR/.git" ]]; then
  ok "unlock tooling already at ${REPO_DIR}"
else
  info "Cloning the unlock tooling into ${REPO_DIR}"
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

# --- 1. inspect the harvest map BEFORE patching anything -------------------

echo
info "CU harvest map (read-only)"
./scripts/cu_map.sh
echo

cat <<TXT
  How to read that:

    ${GRN}contiguous${RST}  ■■■■■■□□□□ in all four shader arrays
                the usual factory harvest — safe to enable all 40

    ${YLW}scattered${RST}   ■■□□■■□□■■
                may be defective silicon. Do NOT blanket-enable. Run the
                per-WGP health test from the upstream repo and mask
                selectively instead.
TXT

if [[ "$MAP_ONLY" -eq 1 ]]; then
  exit 0
fi

echo
confirm "Does the map look contiguous, and do you want to enable all 40 CUs?" \
  || { info "Stopping here. Nothing was changed."; exit 0; }

# --- 2. build the patched module (5-15 min) --------------------------------

info "Building the patched amdgpu module — this takes 5-15 minutes"
./scripts/bc250-enable-40cu.sh build

# --- 3. confirm the parameter is actually in the module --------------------

info "Verifying the module carries the bc250 parameter"
if modinfo amdgpu | grep -i bc250; then
  ok "parameter present"
else
  fail "the built module has no bc250 parameter. The build did not take — do \
NOT reboot expecting 40 CUs. Check the build output above."
fi

# --- 4. activate (writes modprobe.d + initramfs) ---------------------------

info "Activating (writes modprobe.d and regenerates the initramfs)"
./scripts/bc250-enable-40cu.sh enable

reboot_required \
  "sudo dmesg | grep active_cu_number                       # active_cu_number 40" \
  "sudo dmesg | grep bc250-40cu                             # CC 0xfff80000->0xffe00000, SPI 0x07->0x1f" \
  "RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu  # num_cu = 40" \
  "" \
  "Then RE-TUNE the thermals: 40 CUs draw ~125 W where 24 drew ~95 W," \
  "so the old governor ceiling no longer holds. See the README."
