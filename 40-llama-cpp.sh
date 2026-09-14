#!/usr/bin/env bash
# 40-llama-cpp.sh — build llama.cpp with the Vulkan and RPC backends.
#
# Run as your normal user, NOT with sudo (it clones and builds in $HOME).
# Build dependencies need root, so it calls sudo for that one step only.
#
#   --update   pull the latest llama.cpp before building
#   --clean    wipe the build directory and configure from scratch
#
# Deliberately placed BEFORE the 40 CU unlock: you want a known-good,
# measurable baseline first. Unlocking CUs on a box you have never benchmarked
# means any later problem has two possible causes instead of one.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

require_not_root

REPO_DIR="${LLAMA_CPP_DIR:-$HOME/llama.cpp}"
REPO_URL=https://github.com/ggml-org/llama.cpp
DO_UPDATE=0
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) DO_UPDATE=1 ;;
    --clean)  DO_CLEAN=1 ;;
    *) fail "unknown option: $1 (accepts --update, --clean)" ;;
  esac
  shift
done

# --- guard rail: verify Vulkan BEFORE spending 10 minutes compiling ---------

# Without the render group effective, RADV is invisible and the build happily
# produces a binary that only ever finds llvmpipe. The failure then shows up
# as "inference is inexplicably slow" rather than as a build error.
info "Checking that RADV can see the GPU"
have vulkaninfo || fail "vulkaninfo not found — run 10-gpu-drivers.sh first."

VK_SUMMARY="$(vulkaninfo --summary 2>/dev/null || true)"
if grep -q 'radv' <<< "$VK_SUMMARY"; then
  ok "$(grep -m1 'deviceName' <<< "$VK_SUMMARY" | sed 's/^[[:space:]]*//')"
else
  echo "$VK_SUMMARY" | grep -E 'deviceName|driverName' || true
  fail "RADV is not visible to this session. Almost always the render group \
is not effective yet: reconnect your SSH session and try again. See \
10-gpu-drivers.sh."
fi

# --- dependencies ----------------------------------------------------------

info "Installing build dependencies (needs sudo)"
sudo apt-get update -qq
sudo apt-get install -y \
  build-essential cmake git \
  libcurl4-openssl-dev \
  glslc libvulkan-dev spirv-headers spirv-tools

# --- source ----------------------------------------------------------------

if [[ -d "$REPO_DIR/.git" ]]; then
  ok "llama.cpp already cloned at ${REPO_DIR}"
  if [[ "$DO_UPDATE" -eq 1 ]]; then
    info "Pulling latest"
    git -C "$REPO_DIR" pull --ff-only
  else
    info "Building the checked-out revision ($(git -C "$REPO_DIR" rev-parse --short HEAD)). \
Pass --update to pull first."
  fi
else
  info "Cloning llama.cpp into ${REPO_DIR}"
  git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

# --- build -----------------------------------------------------------------

# GGML_VULKAN: the only usable acceleration path on this APU (no ROCm).
# GGML_RPC:    lets this box act as an rpc-server backend so two BC-250s can
#              split one model by layer. Cheap to enable, annoying to add later.
[[ "$DO_CLEAN" -eq 1 ]] && { info "Removing build/"; rm -rf build; }

info "Configuring"
cmake -B build -DGGML_VULKAN=ON -DGGML_RPC=ON

info "Building with $(nproc) jobs — this takes a while"
cmake --build build --config Release -j"$(nproc)"

ok "built: ${REPO_DIR}/build/bin"

cat <<TXT

${BLU}==>${RST} Smoke test with a tiny model:

    cd ${REPO_DIR}
    ./build/bin/llama-bench -hf Qwen/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M -ngl 999

  Record this number. It is the baseline you compare against after the
  40 CU unlock and after any governor change.
TXT
