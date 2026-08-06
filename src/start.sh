#!/usr/bin/env bash
set -Eeuo pipefail
umask 0022

bool_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  printf '[inline-start] %s\n' "$*"
}

persist_runtime_environment() {
  local secret_dir=/root/.secrets
  local session_env="${secret_dir}/env.current"
  local summary="${INLINE_LOG_DIR}/env.summary"
  local name value
  local -a patterns=(
    'ENABLE_*' 'INSTALL_*' 'INLINE_*' 'HF_*' 'HFF_*' '*_TOKEN'
    'SSH_*' 'PUBLIC_KEY' 'MODEL_MANIFEST_URL' 'download_*' '*_URL'
  )
  local -a names=()

  mkdir -p "$secret_dir" "$INLINE_LOG_DIR"
  chmod 700 "$secret_dir"

  while IFS='=' read -r name _; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    for pattern in "${patterns[@]}"; do
      if [[ "$name" == $pattern ]]; then
        names+=("$name")
        break
      fi
    done
  done < <(env)

  mapfile -t names < <(printf '%s\n' "${names[@]:-}" | sed '/^$/d' | sort -u)

  umask 077
  {
    printf '# Generated %s\n' "$(date -Is)"
    for name in "${names[@]}"; do
      [[ ${!name+x} ]] || continue
      value="${!name}"
      [[ -n "$value" ]] || continue
      printf 'export %s=%q\n' "$name" "$value"
    done
  } > "$session_env"
  chmod 600 "$session_env"
  umask 0022

  {
    printf 'Generated: %s\n' "$(date -Is)"
    for name in "${names[@]}"; do
      [[ "$name" =~ (TOKEN|SECRET|PASSWORD|PASS|KEY|CREDENTIAL|COOKIE|AUTH) ]] && continue
      [[ ${!name+x} ]] || continue
      printf '%-36s = %s\n' "$name" "${!name}"
    done
  } > "$summary"
}

prepare_workspace() {
  mkdir -p \
    "$INLINE_STATE_ROOT" \
    "$INLINE_MODELS_DIR" \
    "$INLINE_DATA_DIR" \
    "$INLINE_EXTENSIONS_DIR" \
    "$INLINE_STUDIO_DATA_DIR" \
    "$INLINE_STUDIO_WORKSPACE_DIR" \
    "$INLINE_LOG_DIR" \
    "$HF_HOME" \
    "$HUGGINGFACE_HUB_CACHE" \
    "$HF_XET_CACHE"

  mkdir -p \
    "$INLINE_MODELS_DIR/diffusion_models" \
    "$INLINE_MODELS_DIR/checkpoints" \
    "$INLINE_MODELS_DIR/text_encoders" \
    "$INLINE_MODELS_DIR/vae" \
    "$INLINE_MODELS_DIR/loras" \
    "$INLINE_MODELS_DIR/controlnet" \
    "$INLINE_MODELS_DIR/clip_vision" \
    "$INLINE_MODELS_DIR/upscale_models"

  ln -sfn "$INLINE_MODELS_DIR" /models
  ln -sfn "$INLINE_STUDIO_WORKSPACE_DIR" /projects
}

load_pod_runtime() {
  # Compatibility variables let the generic HF manifest helpers write into
  # Inline Studio's persistent model/log locations without invoking ComfyUI.
  export COMFY_HOME="$INLINE_STATE_ROOT"
  export COMFY_LOGS="$INLINE_LOG_DIR"
  export MODELS_DIR="$INLINE_MODELS_DIR"
  export PY_BIN="$PY"
  export PIP_BIN="$PIP"
  export HF_MANIFEST_STATE_DIR="${HF_MANIFEST_STATE_DIR:-${INLINE_LOG_DIR}/hf_manifest}"

  if [[ -f "$POD_RUNTIME_DIR/helpers_core.sh" ]]; then
    # shellcheck source=/dev/null
    source "$POD_RUNTIME_DIR/helpers_core.sh"
  else
    log "pod-runtime helpers_core.sh is missing; continuing without helper functions."
  fi

  if [[ -f "$POD_RUNTIME_DIR/helpers_hf_manifest.sh" ]]; then
    # shellcheck source=/dev/null
    source "$POD_RUNTIME_DIR/helpers_hf_manifest.sh"
  fi
}

configure_ssh() {
  if ! bool_true "${ENABLE_SSH:-true}"; then
    log "ENABLE_SSH is false; sshd will not start."
    return 0
  fi

  if declare -F setup_ssh >/dev/null 2>&1; then
    setup_ssh || log "pod-runtime setup_ssh returned an error; continuing without SSH."
    return 0
  fi

  log "setup_ssh helper unavailable; SSH was not configured."
}

prepare_hf_tools() {
  # hff itself is already on PATH from /opt/pod-runtime/bin. This optional step
  # creates the pod-runtime managed hf-tools environment when its helper exists.
  if bool_true "${ENABLE_HF_TOOLS_BOOTSTRAP:-false}" \
      && declare -F install_system_hff >/dev/null 2>&1; then
    install_system_hff || log "hf-tools bootstrap failed; bundled hff remains available."
  fi

  if declare -F hf_transfer_tune >/dev/null 2>&1; then
    hf_transfer_tune || true
  fi
}

run_model_manifest() {
  if ! bool_true "${ENABLE_MODEL_MANIFEST_DOWNLOAD:-false}"; then
    log "Model manifest download disabled."
    return 0
  fi

  if [[ -z "${MODEL_MANIFEST_URL:-}" ]]; then
    log "ENABLE_MODEL_MANIFEST_DOWNLOAD=true, but MODEL_MANIFEST_URL is empty."
    return 0
  fi

  if ! declare -F hf_download_from_manifest >/dev/null 2>&1; then
    log "pod-runtime HF manifest helper is unavailable."
    return 1
  fi

  export HF_DOWNLOADER="${HF_DOWNLOADER:-true}"
  log "Starting model manifest download: ${MODEL_MANIFEST_URL}"
  hf_download_from_manifest "$MODEL_MANIFEST_URL"

  if bool_true "${WAIT_FOR_MODEL_DOWNLOADS:-true}" \
      && declare -F hf_download_wait >/dev/null 2>&1; then
    log "Waiting for model downloads before Inline Studio scans the model tree..."
    hf_download_wait "$HF_MANIFEST_STATE_DIR"
  fi
}

print_banner() {
  local inline_commit pod_commit
  inline_commit="$(cat /opt/inline-studio/INLINE_STUDIO_COMMIT 2>/dev/null || echo unknown)"
  pod_commit="$(cat /opt/inline-studio/POD_RUNTIME_COMMIT 2>/dev/null || echo unknown)"

  cat <<BANNER

============================================================
 Inline Studio for RunPod
============================================================
 UI/API              : http://0.0.0.0:${INLINE_PORT}
 Health              : http://127.0.0.1:${INLINE_PORT}/v1/health
 Models              : ${INLINE_MODELS_DIR}
 Projects            : ${INLINE_STUDIO_WORKSPACE_DIR}
 Logs                : ${INLINE_LOG_DIR}
 Inline Studio commit: ${inline_commit}
 pod-runtime commit  : ${pod_commit}
 SSH                 : ${ENABLE_SSH:-true} (requires SSH_PUBLIC_KEY or PUBLIC_KEY)
============================================================

BANNER
}

main() {
  prepare_workspace
  persist_runtime_environment

  local startup_log="${INLINE_LOG_DIR}/startup.log"
  touch "$startup_log"
  exec > >(tee -a "$startup_log") 2>&1

  print_banner
  load_pod_runtime
  configure_ssh
  prepare_hf_tools

  if ! run_model_manifest; then
    if bool_true "${REQUIRE_MODEL_MANIFEST_SUCCESS:-false}"; then
      log "Model manifest failed and REQUIRE_MODEL_MANIFEST_SUCCESS=true; aborting."
      exit 1
    fi
    log "Model manifest reported an error; starting Inline Studio anyway."
  fi

  if (($#)); then
    log "Executing override command: $*"
    exec "$@"
  fi

  log "Starting Inline Studio on ${INLINE_HOST}:${INLINE_PORT}"
  exec "$PY" -m inline_core.server
}

main "$@"
