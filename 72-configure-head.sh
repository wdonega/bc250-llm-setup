#!/usr/bin/env bash
# 72-configure-head.sh — install llama-server as a systemd service.
#
# Run with sudo, ON THE HEAD BOARD. Idempotent.
#
# The head holds its share of the layers plus the KV cache and context
# buffers, serves the OpenAI-compatible API on :8080, and drives the worker
# over RPC. Run 71-configure-worker.sh on the other board first.
#
# Model, context size and worker address live in an EnvironmentFile
# (/etc/default/llama-server) so you can change configuration without editing
# the unit. This script NEVER overwrites an existing one — the values in there
# are tuned per board, and clobbering them on a re-run would silently change
# what you are running. It installs the sample only on first run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_lib.sh"

require_root

SERVICE=llama-server
UNIT_SRC="${SCRIPT_DIR}/${SERVICE}.service"
UNIT_DST="/etc/systemd/system/${SERVICE}.service"
ENV_SRC="${SCRIPT_DIR}/${SERVICE}.env"
ENV_DST="/etc/default/${SERVICE}"
API_PORT=8080

USER_NAME="$(target_user)"
[[ "$USER_NAME" != "root" ]] || fail "could not determine the login user. Run \
as 'sudo ./72-configure-head.sh' from your own account, not a root shell."
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || fail "no home directory for ${USER_NAME}."

# --- guard rails -----------------------------------------------------------

for f in "$UNIT_SRC" "$ENV_SRC"; do
  [[ -f "$f" ]] || fail "${f} is missing — it ships next to this script."
done

BINARY="${USER_HOME}/llama.cpp/build/bin/${SERVICE}"
[[ -x "$BINARY" ]] || fail "${BINARY} not found — run 40-llama-cpp.sh first."
ok "found ${BINARY}"

for g in render video; do
  getent group "$g" > /dev/null || fail "group '${g}' does not exist — run \
10-gpu-drivers.sh first."
done

require_gpu_device_path > /dev/null
ok "BC-250 APU confirmed at $(gpu_device_path)"

# --- environment file ------------------------------------------------------

if [[ -f "$ENV_DST" ]]; then
  ok "${ENV_DST} already exists — leaving your tuned values alone"
else
  install -m 0644 "$ENV_SRC" "$ENV_DST"
  ok "installed ${ENV_DST} from the sample"
  warn "review it before this is load-bearing: the model, context size and \
worker address in there are the ones from my boards."
fi

# Read back whatever is actually configured, ours or theirs.
#
# Parsed rather than sourced, deliberately: `source` would apply shell
# expansion, and systemd's EnvironmentFile does not. Sourcing can therefore
# report a different value than the one the service will actually run with.
env_get() {
  sed -nE "s/^[[:space:]]*$1=[\"']?([^\"']*)[\"']?[[:space:]]*$/\\1/p" "$ENV_DST" | tail -1
}

# Every key the unit interpolates must be present: systemd does not fail on a
# missing one, it substitutes an empty string and llama-server starts with a
# malformed argument list.
for v in LLAMA_MODEL LLAMA_CTX_SIZE LLAMA_ALIAS LLAMA_RPC_WORKER LLAMA_CACHE_TYPE; do
  [[ -n "$(env_get "$v")" ]] || fail "${v} is not set in ${ENV_DST}. The unit \
references it and systemd would start llama-server with an empty argument."
done

LLAMA_MODEL="$(env_get LLAMA_MODEL)"
LLAMA_CTX_SIZE="$(env_get LLAMA_CTX_SIZE)"
LLAMA_RPC_WORKER="$(env_get LLAMA_RPC_WORKER)"
LLAMA_CACHE_TYPE="$(env_get LLAMA_CACHE_TYPE)"
ok "config: ${LLAMA_MODEL}, ctx ${LLAMA_CTX_SIZE}, KV ${LLAMA_CACHE_TYPE}"

# --- is the worker actually there? -----------------------------------------

# Without this check the service comes up and restart-loops every 15s with a
# connection error that looks like a llama.cpp problem rather than a worker
# that was never started.
WORKER_HOST="${LLAMA_RPC_WORKER%:*}"
WORKER_PORT="${LLAMA_RPC_WORKER##*:}"
info "Checking the worker at ${LLAMA_RPC_WORKER}"
if timeout 5 bash -c ">/dev/tcp/${WORKER_HOST}/${WORKER_PORT}" 2>/dev/null; then
  ok "worker is reachable"
else
  warn "cannot reach ${LLAMA_RPC_WORKER}."
  echo "    Run 71-configure-worker.sh on that board first. The head will"
  echo "    retry every 15s, so you can continue and it will pick the worker"
  echo "    up once it appears — it just will not serve until then."
  confirm "Install and start anyway?" || { info "Stopped. Nothing changed."; exit 0; }
fi

# --- render the unit -------------------------------------------------------

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

# Both are in the unit's ReadWritePaths; missing, the model download fails
# under ProtectSystem=strict with a confusing read-only error.
for d in "${USER_HOME}/.cache/huggingface" "${USER_HOME}/.cache/llama.cpp"; do
  if [[ ! -d "$d" ]]; then
    install -d -o "$USER_NAME" -g "$USER_NAME" -m 0755 "$d"
    ok "created ${d}"
  fi
done

# --- start -----------------------------------------------------------------

systemctl daemon-reload
info "Enabling and starting ${SERVICE}"
systemctl enable --now "${SERVICE}.service"
if [[ "$UNIT_CHANGED" -eq 1 ]]; then
  systemctl restart "${SERVICE}.service"
fi

# --- report ----------------------------------------------------------------

# Deliberately NOT `journalctl -f` here: it never returns, which would hang
# any unattended run and leaves you unsure whether the script finished.
cat <<TXT

${GRN} ok ${RST} ${SERVICE} enabled.

${YLW}warn${RST} It is not serving yet. First load pushes half the tensors over the
     network and takes MINUTES (the unit allows up to 900s). Watch it:

      journalctl -u ${SERVICE} -f

    Ready when you see the HTTP server listening on :${API_PORT}. Then:

      curl -s localhost:${API_PORT}/v1/models | jq .

${BLU}==>${RST} To change model, context or KV cache type:

      sudoedit ${ENV_DST}
      sudo systemctl restart ${SERVICE}

    Measured combinations and their memory headroom are in the comments of
    that file. Below ~1.5 GB free the OOM killer becomes a question of when,
    not if.
TXT
