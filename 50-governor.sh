#!/usr/bin/env bash
# 50-governor.sh — cyan-skillfish-governor-smu: clock/voltage control.
#
# Idempotent. Run with sudo.
#
# The stock amdgpu driver has no usable DPM for this APU — it parks the clock
# and stays there. This third-party governor talks to the SMU directly and
# gives you a frequency range, a voltage curve and a thermal ceiling.
#
# It installs governor-config.toml from this directory. That file is a
# STARTING point, not a universal setting: the thermal ceiling is per-board
# and has to be measured again on each one. See the "Thermal tuning"
# section of the README.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

require_root

GOVERNOR_VERSION="0.4.12"
DEB_NAME="cyan-skillfish-governor-smu_${GOVERNOR_VERSION}-1_amd64.deb"
DEB_URL="https://github.com/filippor/cyan-skillfish-governor/releases/download/v${GOVERNOR_VERSION}/${DEB_NAME}"
SERVICE=cyan-skillfish-governor-smu
CONFIG_DIR=/etc/cyan-skillfish-governor-smu
CONFIG_FILE="${CONFIG_DIR}/config.toml"
LOCAL_CONFIG="${SCRIPT_DIR}/governor-config.toml"
WORKDIR=/opt/bc250-governor

# --- guard rail ------------------------------------------------------------

# This thing sets voltages. Running it on the wrong silicon is not a
# configuration mistake, it is a hardware one.
require_gpu_device_path > /dev/null
ok "BC-250 APU confirmed at $(gpu_device_path)"

# --- install ---------------------------------------------------------------

INSTALLED="$(dpkg-query -W -f='${Version}' cyan-skillfish-governor-smu 2>/dev/null || true)"
if [[ "$INSTALLED" == "${GOVERNOR_VERSION}-1" ]]; then
  ok "governor ${INSTALLED} already installed"
else
  [[ -n "$INSTALLED" ]] && info "replacing installed version ${INSTALLED}"
  mkdir -p "$WORKDIR"
  info "Downloading ${DEB_NAME}"
  curl -fsSL -o "${WORKDIR}/${DEB_NAME}" "$DEB_URL"

  info "Installing"
  # dpkg -i fails on missing deps rather than resolving them; --fix-broken
  # afterwards is the standard two-step, not a workaround for a broken package.
  dpkg -i "${WORKDIR}/${DEB_NAME}" || apt-get --fix-broken install -y
  ok "governor ${GOVERNOR_VERSION} installed"
fi

# --- config ----------------------------------------------------------------

[[ -f "$LOCAL_CONFIG" ]] || fail "${LOCAL_CONFIG} is missing — it ships next \
to this script and holds the tuned frequency/voltage curve."

# Cheap sanity check: a truncated or wrong file here means voltages the
# package never intended to set.
grep -q '^\[frequency-range\]' "$LOCAL_CONFIG" \
  || fail "${LOCAL_CONFIG} has no [frequency-range] section — refusing to \
install what does not look like a governor config."

mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_FILE" ]] && cmp -s "$LOCAL_CONFIG" "$CONFIG_FILE"; then
  ok "config.toml already matches ${LOCAL_CONFIG}"
  CONFIG_CHANGED=0
else
  if [[ -f "$CONFIG_FILE" ]]; then
    BAK=$(backup_file "$CONFIG_FILE")
    info "Existing config backed up to ${BAK}"
  fi
  install -m 0644 "$LOCAL_CONFIG" "$CONFIG_FILE"
  ok "installed ${CONFIG_FILE}"
  CONFIG_CHANGED=1
fi

# --- service ---------------------------------------------------------------

info "Enabling and starting ${SERVICE}"
systemctl enable --now "${SERVICE}.service"
[[ "${CONFIG_CHANGED}" -eq 1 ]] && systemctl restart "${SERVICE}.service"

sleep 2
if systemctl is-active --quiet "$SERVICE"; then
  ok "${SERVICE} is running"
else
  systemctl status "$SERVICE" --no-pager || true
  fail "${SERVICE} did not start. Check 'journalctl -u ${SERVICE} -n 50'."
fi

# --- report ----------------------------------------------------------------

echo
info "Frequency range in effect"
sed -nE '/^\[frequency-range\]/,/^\[/p' "$CONFIG_FILE" | grep -E '^(min|max)' || true
info "Thermal ceiling"
sed -nE '/^\[temperature\]/,/^\[/p' "$CONFIG_FILE" | grep -E '^throttling' || true

echo
info "Current DPM state"
cat "$(gpu_device_path)/pp_dpm_sclk" 2>/dev/null || \
  warn "pp_dpm_sclk unavailable"

cat <<TXT

${YLW}warn${RST} The 'max' frequency only governs short bursts. Under sustained
     load the thermal ceiling decides, and that ceiling is per-board. Do not
     assume these numbers transfer — re-measure with a 10-15 minute soak test
     (README, "Thermal tuning").
TXT
