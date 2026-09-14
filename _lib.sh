#!/usr/bin/env bash
# _lib.sh — shared helpers for the BC-250 host scripts.
#
# Not executable on its own. Source it from the numbered scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# --- logging ---------------------------------------------------------------

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YLW=''; BLU=''; RST=''
fi

# warn goes to stdout, not stderr, on purpose: these scripts are often piped
# to a log, and mixing the two streams scrambles the order of the output.
# Only fail() writes to stderr.
info() { echo "${BLU}==>${RST} $*"; }
ok()   { echo "${GRN} ok ${RST} $*"; }
warn() { echo "${YLW}warn${RST} $*"; }
fail() { echo "${RED}FAIL${RST} $*" >&2; exit 1; }

# --- privileges ------------------------------------------------------------

require_root() {
  [[ $EUID -eq 0 ]] || fail "run this with sudo."
}

# Scripts that build or clone into a home directory must NOT run as root:
# under sudo, $HOME is /root and everything lands in the wrong place owned
# by the wrong user.
require_not_root() {
  [[ $EUID -ne 0 ]] || fail "do NOT run this with sudo — it builds in \$HOME \
and running as root would put everything in /root owned by root."
}

# The login user, whether or not we were invoked through sudo.
# $USER is not guaranteed to exist (cron, systemd, a bare container shell) and
# under `set -u` referencing it unset aborts the script, so fall back to id.
target_user() { echo "${SUDO_USER:-${USER:-$(id -un)}}"; }

# --- confirmation ----------------------------------------------------------

# confirm "question" — defaults to NO. Set ASSUME_YES=1 to skip all prompts
# (for unattended runs); anything destructive still logs what it did.
confirm() {
  local prompt="$1" reply
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    info "${prompt} -> yes (ASSUME_YES=1)"
    return 0
  fi
  [[ -t 0 || -e /dev/tty ]] || fail "${prompt} — no terminal to ask on; \
re-run interactively or set ASSUME_YES=1."
  read -r -p "${prompt} [y/N] " reply < /dev/tty
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- BC-250 specifics ------------------------------------------------------

# PCI device ID of the BC-250 APU (Cyan Skillfish). Vendor is 0x1002 (AMD).
BC250_DEVICE_ID=0x13fe

# The DRM card index is NOT stable across reboots — on this board the APU has
# shown up as both card0 and card1. Never hardcode it: resolve by device ID.
# Prints the sysfs device path, e.g. /sys/class/drm/card1/device
gpu_device_path() {
  local c
  for c in /sys/class/drm/card*/device; do
    [[ -r "$c/device" ]] || continue
    if [[ "$(cat "$c/device" 2>/dev/null)" == "$BC250_DEVICE_ID" ]]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

# Same, but aborts with a useful message instead of returning empty.
require_gpu_device_path() {
  local path
  path="$(gpu_device_path)" || fail "no DRM device with id ${BC250_DEVICE_ID} \
found. Either amdgpu did not bind (check 'dmesg | grep amdgpu') or this is \
not a BC-250."
  echo "$path"
}

# --- reboot ----------------------------------------------------------------

# These scripts never reboot on their own. A reboot in the middle of a script
# is indistinguishable from a crash, and some phases need you to look at the
# output before the machine goes down.
reboot_required() {
  echo
  echo "${YLW}────────────────────────────────────────────────────────${RST}"
  echo "${YLW}  REBOOT REQUIRED${RST}"
  echo
  echo "    sudo reboot"
  echo
  if [[ $# -gt 0 ]]; then
    echo "  After it comes back:"
    printf '    %s\n' "$@"
    echo
  fi
  echo "${YLW}────────────────────────────────────────────────────────${RST}"
}

# --- misc ------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Timestamped backup of a file we are about to edit. Prints the backup path.
backup_file() {
  local f="$1" bak
  bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$f" "$bak"
  echo "$bak"
}
