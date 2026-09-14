#!/usr/bin/env bash
# 71-configure-worker.sh — install the RPC worker as a systemd service.
#
# Run with sudo, ON THE WORKER BOARD. Idempotent.
#
# This is the board that holds the second half of the model's layers. It runs
# ggml-rpc-server and nothing else; the head node set up by
# 72-configure-head.sh drives it.
#
# Bring this up FIRST. The head retries on a timer so the reverse order also
# converges, but it wastes a few minutes in restart loops.
#
# SECURITY: llama.cpp's RPC protocol has no authentication and no input
# validation. Anyone who can reach port 50052 can execute code on this
# machine. The unit restricts traffic to RFC1918 ranges via IPAddressAllow,
# but that is a backstop, not a substitute for not exposing the port.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

require_root

SERVICE=ggml-rpc-server
UNIT_SRC="${SCRIPT_DIR}/${SERVICE}.service"
UNIT_DST="/etc/systemd/system/${SERVICE}.service"
RPC_PORT=50052

USER_NAME="$(target_user)"
[[ "$USER_NAME" != "root" ]] || fail "could not determine the login user. Run \
as 'sudo ./71-configure-worker.sh' from your own account, not a root shell."
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || fail "no home directory for ${USER_NAME}."

# --- guard rails -----------------------------------------------------------

[[ -f "$UNIT_SRC" ]] || fail "${UNIT_SRC} is missing — it ships next to this script."

BINARY="${USER_HOME}/llama.cpp/build/bin/${SERVICE}"
# Built without -DGGML_RPC=ON there is no RPC binary at all, and the service
# would fail on every restart with a bare 203/EXEC and no useful message.
[[ -x "$BINARY" ]] || fail "${BINARY} not found. Either llama.cpp is not built \
yet (run 40-llama-cpp.sh) or it was built without -DGGML_RPC=ON, which \
produces no RPC binary. Rebuild with: ./40-llama-cpp.sh --clean"
ok "found ${BINARY}"

# The unit relies on SupplementaryGroups=render video. A missing group here
# means the service starts but gets no GPU.
for g in render video; do
  getent group "$g" > /dev/null || fail "group '${g}' does not exist — run \
10-gpu-drivers.sh first."
done

require_gpu_device_path > /dev/null
ok "BC-250 APU confirmed at $(gpu_device_path)"

# --- render the unit -------------------------------------------------------

# The unit in the repo is a template: __USER__ and __HOME__ are substituted
# here, so the same file works on any host whatever the account is called.
TMP_UNIT="$(mktemp)"
trap 'rm -f "$TMP_UNIT"' EXIT
sed -e "s|__USER__|${USER_NAME}|g" -e "s|__HOME__|${USER_HOME}|g" \
  "$UNIT_SRC" > "$TMP_UNIT"

if grep -q '__USER__\|__HOME__' "$TMP_UNIT"; then
  fail "unsubstituted placeholder left in the rendered unit — bug in the template."
fi

if [[ -f "$UNIT_DST" ]] && cmp -s "$TMP_UNIT" "$UNIT_DST"; then
  ok "${UNIT_DST} is already up to date"
  UNIT_CHANGED=0
else
  if [[ -f "$UNIT_DST" ]]; then
    BAK=$(backup_file "$UNIT_DST")
    info "existing unit backed up to ${BAK}"
  fi
  install -m 0644 "$TMP_UNIT" "$UNIT_DST"
  ok "installed ${UNIT_DST} (User=${USER_NAME}, home=${USER_HOME})"
  UNIT_CHANGED=1
fi

# This directory is in the unit's ReadWritePaths. Without it the service still
# starts, but re-fetches tensors over the network on every head restart.
CACHE_DIR="${USER_HOME}/.cache/llama.cpp"
if [[ ! -d "$CACHE_DIR" ]]; then
  install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "$CACHE_DIR"
  ok "created ${CACHE_DIR} (tensor cache — avoids re-sending the model)"
fi

# --- start -----------------------------------------------------------------

systemctl daemon-reload
info "Enabling and starting ${SERVICE}"
systemctl enable --now "${SERVICE}.service"
if [[ "$UNIT_CHANGED" -eq 1 ]]; then
  systemctl restart "${SERVICE}.service"
fi

sleep 3
if systemctl is-active --quiet "$SERVICE"; then
  ok "${SERVICE} is running"
else
  systemctl status "$SERVICE" --no-pager || true
  fail "${SERVICE} did not start. Check 'journalctl -u ${SERVICE} -n 50'."
fi

# --- report ----------------------------------------------------------------

echo
info "Listening sockets"
if have ss; then
  ss -lntp 2>/dev/null | grep ":${RPC_PORT}" || warn "nothing on port \
${RPC_PORT} yet — re-check with: ss -lntp | grep ${RPC_PORT}"
fi

WORKER_ADDR="$(hostname -f 2>/dev/null || hostname):${RPC_PORT}"
cat <<TXT

${GRN} ok ${RST} Worker ready.

${BLU}==>${RST} On the head node, set LLAMA_RPC_WORKER to:

      ${WORKER_ADDR}

    then run 72-configure-head.sh there.

${YLW}warn${RST} Port ${RPC_PORT} grants code execution to anything that can reach
     it. Keep it on the internal LAN and firewalled from everything else.
TXT
