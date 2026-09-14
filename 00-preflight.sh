#!/usr/bin/env bash
# 00-preflight.sh — read-only sanity check before touching the host.
#
# Confirms this really is a BC-250, that the BIOS work was done, and that the
# thermal situation is sane. Changes nothing, so it is safe to run at any
# point (it doubles as a quick "what state is this board in?" probe).
#
# The two BIOS items cannot be automated from inside the OS — do them at the
# console before the first boot:
#   - IOMMU: disabled   (stability requirement on these boards)
#   - Dedicated VRAM: 1 GB (leave the rest of the RAM for GTT / the model)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

PROBLEMS=0
note_problem() { warn "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# --- hardware --------------------------------------------------------------

info "Looking for the BC-250 APU on the PCI bus"
if have lspci && lspci -nn 2>/dev/null | grep -qi '1002:13fe'; then
  ok "$(lspci -nn | grep -i '1002:13fe' | head -1)"
else
  note_problem "no 1002:13fe device in lspci — this may not be a BC-250 \
(install pciutils if lspci is missing)."
fi

if GPU_PATH="$(gpu_device_path)"; then
  ok "amdgpu bound at ${GPU_PATH} (card $(basename "$(dirname "$GPU_PATH")"))"
else
  note_problem "amdgpu has not bound to the APU. Check 'dmesg | grep amdgpu'."
fi

# --- OS --------------------------------------------------------------------

info "OS and kernel"
echo "    $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
echo "    kernel $(uname -r)"

# --- IOMMU -----------------------------------------------------------------

# There is no single reliable flag for "IOMMU is off", so report the evidence
# instead of pretending to a verdict: a populated iommu_groups tree means the
# IOMMU is active, which is what we do not want here.
info "IOMMU state (must be disabled in the BIOS)"
IOMMU_GROUPS=0
[[ -d /sys/kernel/iommu_groups ]] && \
  IOMMU_GROUPS=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d | wc -l)
if [[ "$IOMMU_GROUPS" -eq 0 ]]; then
  ok "no IOMMU groups — IOMMU looks disabled"
else
  note_problem "${IOMMU_GROUPS} IOMMU groups present — the IOMMU is active. \
Disable it in the BIOS; leaving it on is the known instability on these boards."
fi

# --- memory ----------------------------------------------------------------

info "Memory"
MEM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
echo "    RAM visible to the OS: ~${MEM_GB} GB"
echo "    kernel cmdline: $(tr ' ' '\n' < /proc/cmdline | grep '^ttm\.' | tr '\n' ' ' || true)"

if [[ -n "${GPU_PATH:-}" && -r "${GPU_PATH}/mem_info_gtt_total" ]]; then
  GTT_BYTES=$(cat "${GPU_PATH}/mem_info_gtt_total")
  echo "    GTT total: $(( GTT_BYTES / 1024 / 1024 )) MiB"
  # Default GTT is roughly half of RAM; 30-ram-gtt.sh raises it to 14 GiB.
  [[ "$GTT_BYTES" -lt $(( 12 * 1024 * 1024 * 1024 )) ]] && \
    info "GTT is still at its default — run 30-ram-gtt.sh to raise it."
fi

# --- thermals --------------------------------------------------------------

# Idle temperature is the single best proxy for whether the cooling rework
# was done properly. See the README: target is ~52 °C idle; 70 °C+ at idle
# means dried-out paste, blocked fins, or fans on a 5 V rail.
info "Idle temperature"
if have sensors; then
  TEMP=$(sensors 2>/dev/null | grep -A3 amdgpu | grep -oE '\+[0-9]+\.[0-9]+°C' | head -1 || true)
  if [[ -n "$TEMP" ]]; then
    echo "    amdgpu: ${TEMP}"
    TEMP_INT=${TEMP#+}; TEMP_INT=${TEMP_INT%%.*}
    if [[ "$TEMP_INT" -ge 70 ]]; then
      note_problem "idle temperature ${TEMP}. Something is wrong with the \
cooling — do not start tuning clocks until this is fixed (README section 2)."
    else
      ok "idle temperature within expectations"
    fi
  else
    info "sensors installed but no amdgpu reading yet — run 20-sensors.sh"
  fi
else
  info "lm-sensors not installed yet — run 20-sensors.sh"
fi

# --- summary ---------------------------------------------------------------

echo
if [[ "$PROBLEMS" -eq 0 ]]; then
  ok "preflight clean — continue with 10-gpu-drivers.sh"
else
  warn "${PROBLEMS} item(s) above need attention before continuing."
  exit 1
fi
