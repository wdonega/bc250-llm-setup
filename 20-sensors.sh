#!/usr/bin/env bash
# 20-sensors.sh — lm-sensors, including the Nuvoton chip on this board.
#
# Idempotent. Run with sudo.
#
# Without this you are tuning clocks blind, and on this board the thermal
# ceiling is the real limit — not the frequency cap.
#
# WHY force=true: the nct6683 driver refuses to bind unless it recognises the
# firmware's customer ID, and the BC-250's is not in its table. force=true
# tells it to bind anyway. This is the documented workaround for these boards;
# the sensor readings it produces are correct.
#
# NOTE ON FANS: the fans on these boards are wired straight to the PSU. There
# is no PWM and no software fan curve, so there is nothing here to configure —
# `sensors` is read-only telemetry. The governor controls clocks, not airflow.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_root

MODPROBE_CONF=/etc/modprobe.d/bc250-sensors.conf
MODULES_CONF=/etc/modules-load.d/99-bc250-sensors.conf

info "Installing lm-sensors"
apt-get update -qq
apt-get install -y lm-sensors

# sensors-detect --auto writes /etc/modules-load.d/lm-sensors.conf and is
# safe to re-run: it rewrites the same file rather than appending.
info "Probing for sensor chips"
sensors-detect --auto

info "Reloading kernel modules"
systemctl restart kmod || warn "kmod service restart failed — not fatal, \
the modules-load.d entry below still applies at boot."

info "Loading nct6683 with force=true"
if modprobe nct6683 force=true 2>/dev/null; then
  ok "nct6683 loaded"
elif lsmod | grep -q '^nct6683'; then
  ok "nct6683 already loaded"
else
  warn "nct6683 refused to load. amdgpu temperatures will still work; you \
lose the board-level sensors. Check 'dmesg | tail'."
fi

info "Making it persistent"
# Write, don't append: appending on a re-run would duplicate the option and
# the file would grow every time the script is executed.
echo 'options nct6683 force=true' > "$MODPROBE_CONF"
echo 'nct6683' > "$MODULES_CONF"
ok "${MODPROBE_CONF} and ${MODULES_CONF} written"

echo
info "Current readings"
sensors

echo
if sensors 2>/dev/null | grep -q amdgpu; then
  ok "amdgpu temperature is readable — that is the one that matters for tuning"
else
  warn "no amdgpu section in 'sensors' output. Check that the driver bound \
(00-preflight.sh) before relying on these numbers."
fi
