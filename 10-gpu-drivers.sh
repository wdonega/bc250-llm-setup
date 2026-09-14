#!/usr/bin/env bash
# 10-gpu-drivers.sh — Mesa/RADV Vulkan stack + GPU device permissions.
#
# Idempotent. Run with sudo.
#
# THE GOTCHA: adding the user to render/video only takes effect in a NEW
# login session. Until then Vulkan silently falls back to llvmpipe (CPU
# rasterizer) and everything looks like a broken driver. This script does not
# try to work around that with `newgrp` — that spawns a subshell and would
# leave the rest of the script running in the wrong context. Reconnect your
# SSH session instead; it is the predictable path.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_root

PACKAGES=(
  mesa-vulkan-drivers   # RADV, the Vulkan driver that drives this APU
  libvulkan1 libvulkan-dev
  vulkan-tools           # vulkaninfo
  mesa-utils
  pciutils
)

USER_NAME="$(target_user)"
[[ "$USER_NAME" != "root" ]] || fail "could not determine the login user. \
Run as 'sudo ./10-gpu-drivers.sh' from your own account, not from a root shell."

info "Installing the Vulkan stack"
apt-get update -qq
apt-get install -y "${PACKAGES[@]}"
ok "packages installed"

info "Granting ${USER_NAME} access to the GPU devices"
if id -nG "$USER_NAME" | grep -qw render && id -nG "$USER_NAME" | grep -qw video; then
  ok "${USER_NAME} is already in render and video"
else
  usermod -aG render,video "$USER_NAME"
  ok "added ${USER_NAME} to render,video"
fi

# Is the group already effective in the *calling* session? If yes we can
# verify right now; if not, verification has to wait for a reconnect.
if id -nG "$USER_NAME" 2>/dev/null | grep -qw render && \
   sudo -u "$USER_NAME" id -nG | grep -qw render; then
  GROUP_EFFECTIVE=1
else
  GROUP_EFFECTIVE=0
fi

echo
if [[ "$GROUP_EFFECTIVE" -eq 1 ]]; then
  info "Checking what Vulkan sees"
  sudo -u "$USER_NAME" vulkaninfo --summary 2>/dev/null | \
    grep -E 'deviceName|driverName' || true
  echo
  info "You want to see:"
  echo "    deviceName = AMD BC-250 (RADV GFX1013)"
  echo "    driverName = radv"
  echo
  echo "  llvmpipe showing up *alongside* it is normal. llvmpipe as the only"
  echo "  device means the group is not effective yet — reconnect and retry."
  echo "  DISPLAY / DisplayPlaneProperties warnings are headless-server noise."
else
  echo "${YLW}────────────────────────────────────────────────────────${RST}"
  echo "${YLW}  RECONNECT YOUR SESSION${RST}"
  echo
  echo "  The render group is not effective in this session yet."
  echo
  echo "    exit          # then ssh back in"
  echo "    id            # confirm 'render' is in the effective id"
  echo "    vulkaninfo --summary"
  echo
  echo "  Expected: deviceName = AMD BC-250 (RADV GFX1013), driverName = radv"
  echo "  If llvmpipe is the ONLY device listed, this step did not take."
  echo "${YLW}────────────────────────────────────────────────────────${RST}"
fi
