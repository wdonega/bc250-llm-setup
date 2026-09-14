#!/usr/bin/env bash
# 90-validate.sh — read-only end-to-end check of a configured BC-250 host.
#
# Changes nothing. Run it after any reboot, after a kernel upgrade, and
# whenever performance looks off — most of the failure modes on this board are
# silent (you get a working system that is just quietly slow).
#
# Exit code is the number of failed checks, so it works in a cron/monitoring
# context too.
set -uo pipefail   # no -e: we want every check to run, not stop at the first
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

PASS=0; FAILED=0
check_ok()   { ok "$*";   PASS=$((PASS + 1)); }
check_fail() { warn "$*"; FAILED=$((FAILED + 1)); }

echo "BC-250 host validation — $(hostname) — $(date -Is)"
echo

# --- 1. GPU present and bound ----------------------------------------------

info "GPU"
if GPU_PATH="$(gpu_device_path)"; then
  check_ok "amdgpu bound at ${GPU_PATH}"
else
  check_fail "no BC-250 DRM device found (looked for ${BC250_DEVICE_ID})"
  GPU_PATH=""
fi

# --- 2. Vulkan sees RADV, not just llvmpipe --------------------------------

if have vulkaninfo; then
  VK="$(vulkaninfo --summary 2>/dev/null || true)"
  if grep -q radv <<< "$VK"; then
    check_ok "RADV active: $(grep -m1 deviceName <<< "$VK" | sed 's/^[[:space:]]*//')"
  else
    check_fail "RADV not visible — only llvmpipe. The render group is probably \
not effective in this session (reconnect), or the driver did not load."
  fi
else
  check_fail "vulkaninfo missing — run 10-gpu-drivers.sh"
fi

# --- 3. render group -------------------------------------------------------

if id -nG | grep -qw render; then
  check_ok "render group effective for $(id -un)"
else
  check_fail "$(id -un) does not have 'render' in its effective groups"
fi

# --- 4. GTT ----------------------------------------------------------------

info "Memory"
if grep -q 'ttm.pages_limit=' /proc/cmdline; then
  check_ok "TTM limits on the kernel cmdline: $(tr ' ' '\n' < /proc/cmdline | grep '^ttm\.' | tr '\n' ' ')"
else
  check_fail "no ttm.pages_limit on the cmdline — run 30-ram-gtt.sh (GTT will \
be capped around half of RAM)"
fi

if [[ -n "$GPU_PATH" && -r "${GPU_PATH}/mem_info_gtt_total" ]]; then
  GTT_MIB=$(( $(cat "${GPU_PATH}/mem_info_gtt_total") / 1024 / 1024 ))
  if [[ "$GTT_MIB" -ge 12288 ]]; then
    check_ok "GTT total ${GTT_MIB} MiB"
  else
    check_fail "GTT total only ${GTT_MIB} MiB — limits not in effect yet (reboot?)"
  fi
fi

# --- 5. governor -----------------------------------------------------------

info "Governor"
if systemctl is-active --quiet cyan-skillfish-governor-smu 2>/dev/null; then
  check_ok "cyan-skillfish-governor-smu running ($(dpkg-query -W -f='${Version}' cyan-skillfish-governor-smu 2>/dev/null || echo '?'))"
  if [[ -r /etc/cyan-skillfish-governor-smu/config.toml ]]; then
    GOV_CFG=/etc/cyan-skillfish-governor-smu/config.toml
    GOV_MAX=$(grep -E '^max[[:space:]]*=' "$GOV_CFG" | grep -oE '[0-9]+' | head -1)
    GOV_TEMP=$(grep -E '^throttling[[:space:]]*=' "$GOV_CFG" | grep -oE '[0-9]+' | head -1)
    echo "    burst ceiling ${GOV_MAX:-?} MHz, throttling at ${GOV_TEMP:-?} C"
  fi
else
  check_fail "cyan-skillfish-governor-smu not running — run 50-governor.sh"
fi

if [[ -n "$GPU_PATH" && -r "${GPU_PATH}/pp_dpm_sclk" ]]; then
  echo "    current DPM: $(grep '\*' "${GPU_PATH}/pp_dpm_sclk" | tr -s ' ')"
fi

# --- 6. CU count -----------------------------------------------------------

info "Compute units"
CU=$(RADV_DEBUG=info vulkaninfo --summary 2>/dev/null | grep -oE 'num_cu[^0-9]*[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
if [[ -n "$CU" ]]; then
  if [[ "$CU" -eq 40 ]]; then
    check_ok "num_cu = 40 (unlock active)"
  else
    check_fail "num_cu = ${CU}, not 40. If you ran 60-unlock-40cu.sh, a kernel \
upgrade has reverted it — re-run the build against $(uname -r)."
  fi
else
  info "could not read num_cu (RADV_DEBUG output unavailable)"
fi

if modinfo amdgpu 2>/dev/null | grep -qi bc250; then
  check_ok "amdgpu module carries the bc250 parameter"
else
  info "amdgpu is the stock module (no 40 CU unlock applied)"
fi

# --- 7. thermals -----------------------------------------------------------

info "Thermals"
if have sensors; then
  TEMP=$(sensors 2>/dev/null | grep -A3 amdgpu | grep -oE '\+[0-9]+\.[0-9]+°C' | head -1 || true)
  if [[ -n "$TEMP" ]]; then
    TEMP_INT=${TEMP#+}; TEMP_INT=${TEMP_INT%%.*}
    if [[ "$TEMP_INT" -ge 70 ]]; then
      check_fail "GPU at ${TEMP} — if this is idle, the cooling needs work \
before any tuning is meaningful"
    else
      check_ok "GPU at ${TEMP}"
    fi
  else
    check_fail "no amdgpu temperature reading — run 20-sensors.sh"
  fi
else
  check_fail "lm-sensors not installed — run 20-sensors.sh"
fi

# --- 8. IOMMU --------------------------------------------------------------

IOMMU_GROUPS=0
[[ -d /sys/kernel/iommu_groups ]] && \
  IOMMU_GROUPS=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
if [[ "$IOMMU_GROUPS" -eq 0 ]]; then
  check_ok "IOMMU disabled"
else
  check_fail "IOMMU active (${IOMMU_GROUPS} groups) — disable it in the BIOS"
fi

# --- 9. llama.cpp ----------------------------------------------------------

info "llama.cpp"
LLAMA_DIR="${LLAMA_CPP_DIR:-${HOME}/llama.cpp}"
if [[ -x "${LLAMA_DIR}/build/bin/llama-bench" ]]; then
  check_ok "built at ${LLAMA_DIR} ($(git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))"
else
  info "no build at ${LLAMA_DIR} — run 40-llama-cpp.sh (or set LLAMA_CPP_DIR)"
fi

# --- summary ---------------------------------------------------------------

echo
if [[ "$FAILED" -eq 0 ]]; then
  ok "${PASS} checks passed, none failed"
else
  warn "${PASS} passed, ${FAILED} FAILED — see above"
fi
exit "$FAILED"
