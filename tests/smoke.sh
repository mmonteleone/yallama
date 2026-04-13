#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/yallama"
TEST_ROOT="$(mktemp -d)"

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
  rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

pass() {
  printf 'ok - %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'not ok - %s\n' "$1"
  printf '  %s\n' "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

expected_arch() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) printf 'macos-arm64\n' ;;
    Darwin:x86_64) printf 'macos-x86_64\n' ;;
    Linux:x86_64|Linux:amd64) printf 'ubuntu-x64\n' ;;
    Linux:aarch64) printf 'ubuntu-arm64\n' ;;
    *)
      printf 'unsupported platform for smoke tests: %s/%s\n' "$(uname -s)" "$(uname -m)" >&2
      exit 1
      ;;
  esac
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    return 1
  fi
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  [[ "$actual" == "$expected" ]]
}

run_cmd() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  RUN_STATUS=$?
  set -e
}

create_fixture_tarball() {
  local fixtures_dir="$1"
  local tag="$2"
  local asset_arch="$3"
  local stage_dir="${fixtures_dir}/llama-${tag}"
  local archive_path="${fixtures_dir}/llama-${tag}-bin-${asset_arch}.tar.gz"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  printf '#!/usr/bin/env bash\necho llama-cli %s\n' "$tag" >"${stage_dir}/llama-cli"
  printf '#!/usr/bin/env bash\necho llama-server %s\n' "$tag" >"${stage_dir}/llama-server"
  chmod +x "${stage_dir}/llama-cli" "${stage_dir}/llama-server"

  (
    cd "$fixtures_dir"
    tar -czf "$archive_path" "llama-${tag}"
  )

  rm -rf "$stage_dir"
}

write_release_json() {
  local fixtures_dir="$1"
  local tag="$2"
  local asset_arch="$3"
  local json_path="${fixtures_dir}/release-${tag}.json"
  local asset_name="llama-${tag}-bin-${asset_arch}.tar.gz"

  cat >"$json_path" <<EOF
{
  "tag_name": "${tag}",
  "assets": [
    {
      "name": "${asset_name}",
      "browser_download_url": "https://example.invalid/downloads/${asset_name}"
    }
  ]
}
EOF
}

write_latest_pointer() {
  local state_dir="$1"
  local tag="$2"
  printf '%s\n' "$tag" >"${state_dir}/latest-tag"
}

write_mock_curl() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    -H|--connect-timeout|--max-time|--retry|--retry-delay)
      shift 2
      ;;
    -f|-s|-S|-L|-fsSL|-fL)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[[ -n "$url" ]] || {
  echo "mock curl: missing URL" >&2
  exit 1
}

printf '%s\n' "$url" >>"${YALLAMA_TEST_LOG_DIR}/curl.log"

if [[ "$url" == *"/releases/latest" ]]; then
  tag="$(cat "${YALLAMA_TEST_STATE_DIR}/latest-tag")"
  cat "${YALLAMA_TEST_FIXTURES_DIR}/release-${tag}.json"
  exit 0
fi

if [[ "$url" == *"/releases/tags/"* ]]; then
  tag="${url##*/}"
  cat "${YALLAMA_TEST_FIXTURES_DIR}/release-${tag}.json"
  exit 0
fi

if [[ "$url" == *"/downloads/"* ]]; then
  asset_name="${url##*/}"
  cp "${YALLAMA_TEST_FIXTURES_DIR}/${asset_name}" "$output"
  exit 0
fi

echo "mock curl: unhandled URL $url" >&2
exit 1
EOF
  chmod +x "$path"
}

setup_test_env() {
  TEST_DIR="$(mktemp -d "${TEST_ROOT}/case.XXXXXX")"
  export HOME="${TEST_DIR}/home"
  export YALLAMA_TEST_FIXTURES_DIR="${TEST_DIR}/fixtures"
  export YALLAMA_TEST_STATE_DIR="${TEST_DIR}/state"
  export YALLAMA_TEST_LOG_DIR="${TEST_DIR}/logs"
  export PATH="${TEST_DIR}/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  mkdir -p "$HOME" "$YALLAMA_TEST_FIXTURES_DIR" "$YALLAMA_TEST_STATE_DIR" "$YALLAMA_TEST_LOG_DIR" "${TEST_DIR}/bin"
  write_mock_curl "${TEST_DIR}/bin/curl"
}

test_top_level_help() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" help
  if [[ $RUN_STATUS -eq 0 ]] && assert_contains "$(cat "$stdout_file")" 'Commands:' && assert_contains "$(cat "$stdout_file")" 'install'; then
    pass 'top-level help output'
  else
    fail 'top-level help output' "expected help to list commands"
  fi
}

test_argument_parsing_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --print-latest-tag --path /tmp/demo
  if [[ $RUN_STATUS -ne 0 ]] && assert_contains "$(cat "$stderr_file")" '--print-latest-tag cannot be combined'; then
    pass 'install argument conflict'
  else
    fail 'install argument conflict' "expected conflicting install args to fail"
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run some/model --bogus
  if [[ $RUN_STATUS -ne 0 ]] && assert_contains "$(cat "$stderr_file")" 'Unknown argument'; then
    pass 'run argument validation'
  else
    fail 'run argument validation' "expected run to reject arguments before --"
  fi
}

test_install_flow() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  arch="$(expected_arch)"
  create_fixture_tarball "$YALLAMA_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$YALLAMA_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$YALLAMA_TEST_STATE_DIR" 'b1000'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mocked install flow' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${install_root}/llama-b1000/.install-complete" ]]; then
    fail 'mocked install flow' 'expected install marker file to exist'
    return
  fi

  if [[ ! -L "${install_root}/current" ]]; then
    fail 'mocked install flow' 'expected current symlink to be created'
    return
  fi

  if ! assert_eq "$(basename "$(readlink "${install_root}/current")")" 'llama-b1000'; then
    fail 'mocked install flow' 'expected current symlink to point at llama-b1000'
    return
  fi

  if ! assert_contains "$(cat "${YALLAMA_TEST_LOG_DIR}/curl.log")" "llama-b1000-bin-${arch}.tar.gz"; then
    fail 'arch detection in install flow' 'expected asset download to match detected architecture'
    return
  fi

  pass 'mocked install flow'
  pass 'arch detection in install flow'
}

test_update_flow() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  arch="$(expected_arch)"
  create_fixture_tarball "$YALLAMA_TEST_FIXTURES_DIR" 'b1000' "$arch"
  create_fixture_tarball "$YALLAMA_TEST_FIXTURES_DIR" 'b1001' "$arch"
  write_release_json "$YALLAMA_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$YALLAMA_TEST_FIXTURES_DIR" 'b1001' "$arch"

  write_latest_pointer "$YALLAMA_TEST_STATE_DIR" 'b1000'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mocked update flow' "initial install failed: $(cat "$stderr_file")"
    return
  fi

  write_latest_pointer "$YALLAMA_TEST_STATE_DIR" 'b1001'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" update --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mocked update flow' "update failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_eq "$(basename "$(readlink "${install_root}/current")")" 'llama-b1001'; then
    fail 'mocked update flow' 'expected current symlink to point at llama-b1001 after update'
    return
  fi

  if [[ ! -f "${install_root}/llama-b1001/.install-complete" ]]; then
    fail 'mocked update flow' 'expected updated install marker file to exist'
    return
  fi

  pass 'mocked update flow'
}

test_pull_noninteractive() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local args_log="${TEST_DIR}/llama-cli-args.log"
  local model_name='demo/test-model'
  local expected_cache_dir="${HOME}/.cache/huggingface/hub/models--demo--test-model"

  mkdir -p "$current_link" "$(dirname "$expected_cache_dir")"
  : >"$args_log"

  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >"$YALLAMA_LLAMA_CLI_ARGS_LOG"

if [[ -t 0 ]]; then
  echo 'stdin should not be attached to a terminal during pull' >&2
  exit 42
fi

if read -r _; then
  echo 'stdin should be EOF during pull' >&2
  exit 43
fi

mkdir -p "$YALLAMA_EXPECTED_CACHE_DIR"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  export YALLAMA_INSTALL_ROOT="$install_root"
  export YALLAMA_EXPECTED_CACHE_DIR="$expected_cache_dir"
  export YALLAMA_LLAMA_CLI_ARGS_LOG="$args_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull "$model_name"

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'non-interactive pull' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -d "$expected_cache_dir" ]]; then
    fail 'non-interactive pull' 'expected pull to create the model cache dir'
    return
  fi

  if ! assert_contains "$(cat "$args_log")" '--no-conversation'; then
    fail 'non-interactive pull' 'expected pull to force non-conversation mode'
    return
  fi

  if ! assert_contains "$(cat "$args_log")" "--prompt  "; then
    fail 'non-interactive pull' 'expected pull to pass a non-empty placeholder prompt'
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Done: ${model_name}"; then
    fail 'non-interactive pull' 'expected pull to report success'
    return
  fi

  pass 'non-interactive pull'
}

test_status_and_versions() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local arch

  arch="$(expected_arch)"
  create_fixture_tarball "$YALLAMA_TEST_FIXTURES_DIR" 'b1002' "$arch"
  write_release_json "$YALLAMA_TEST_FIXTURES_DIR" 'b1002' "$arch"
  write_latest_pointer "$YALLAMA_TEST_STATE_DIR" 'b1002'

  mkdir -p "${install_root}/llama-b1000" "${install_root}/llama-b1001"
  ln -sfn "${install_root}/llama-b1001" "${install_root}/current"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --path "$install_root"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'status output for installed version' "status failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'Installed : b1001'; then
    fail 'status output for installed version' 'expected status to report installed tag b1001'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --path "$install_root" --check-update
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'status check-update output' "status --check-update failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'Latest    : b1002 (update available'; then
    fail 'status check-update output' 'expected status to report newer upstream tag'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" versions --path "$install_root"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'versions output marks current' "versions failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'b1001  (current)'; then
    fail 'versions output marks current' 'expected versions output to mark the active version'
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'b1000'; then
    fail 'versions output lists all installed tags' 'expected versions output to include inactive versions'
    return
  fi

  pass 'status output for installed version'
  pass 'status check-update output'
  pass 'versions output marks current'
  pass 'versions output lists all installed tags'
}

test_prune_and_uninstall() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local hf_hub_dir="${HOME}/.cache/huggingface/hub"

  mkdir -p "${install_root}/llama-b1000" "${install_root}/llama-b1001"
  ln -sfn "${install_root}/llama-b1001" "${install_root}/current"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" prune --path "$install_root" --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'prune removes inactive versions' "prune failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "${install_root}/llama-b1000" ]] || [[ ! -d "${install_root}/llama-b1001" ]]; then
    fail 'prune removes inactive versions' 'expected prune to remove only non-current installs'
    return
  fi

  mkdir -p "${hf_hub_dir}/models--demo--model-a" "${hf_hub_dir}/models--demo--model-b"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" uninstall --path "$install_root" --delete-hf-cache --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'uninstall removes install and hf cache' "uninstall failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "$install_root" ]] || [[ -d "${hf_hub_dir}/models--demo--model-a" ]] || [[ -d "${hf_hub_dir}/models--demo--model-b" ]]; then
    fail 'uninstall removes install and hf cache' 'expected uninstall to remove install root and HF model dirs'
    return
  fi

  pass 'prune removes inactive versions'
  pass 'uninstall removes install and hf cache'
}

test_remove_model_force() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='demo/test-model'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--demo--test-model"

  # Create two quant fixtures so the listing is exercised.
  create_gguf_fixture "models--demo--test-model" "test-model-Q4_K_M.gguf" 1024
  create_gguf_fixture "models--demo--test-model" "test-model-Q8_0.gguf" 2048

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove "$model_name" --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove deletes cached model' "remove failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "$cache_dir" ]]; then
    fail 'remove deletes cached model' 'expected remove to delete model cache directory'
    return
  fi

  local out; out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'demo/test-model:Q4_K_M'; then
    fail 'remove lists quant variants before deleting' "expected quant listing to include Q4_K_M, got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/test-model:Q8_0'; then
    fail 'remove lists quant variants before deleting' "expected quant listing to include Q8_0, got: $out"
    return
  fi

  pass 'remove deletes cached model'
  pass 'remove lists quant variants before deleting'
}

test_run_and_serve_forwarding() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_args_log="${TEST_DIR}/run-args.log"
  local serve_args_log="${TEST_DIR}/serve-args.log"

  mkdir -p "$current_link"

  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$YALLAMA_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$YALLAMA_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"

  export YALLAMA_INSTALL_ROOT="$install_root"
  export YALLAMA_RUN_ARGS_LOG="$run_args_log"
  export YALLAMA_SERVE_ARGS_LOG="$serve_args_log"
  export HF_TOKEN='hf_test_token'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run demo/run-model -- --threads 4
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'run forwards model and extra args' "run failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$run_args_log")" '-hf demo/run-model --hf-token hf_test_token --threads 4'; then
    fail 'run forwards model and extra args' 'expected run to forward model, hf token, and extra args to llama-cli'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve demo/serve-model -- --port 8081
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'serve forwards jinja and extra args' "serve failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$serve_args_log")" '-hf demo/serve-model --jinja --hf-token hf_test_token --port 8081'; then
    fail 'serve forwards jinja and extra args' 'expected serve to forward model, --jinja, hf token, and extra args to llama-server'
    return
  fi

  pass 'run forwards model and extra args'
  pass 'serve forwards jinja and extra args'
}

# ── quant-aware tests ─────────────────────────────────────────────────────────

# Helper: create a fake GGUF file in the HF cache with a symlinked blob.
create_gguf_fixture() {
  local model_dir_name="$1"  # e.g., "models--demo--test-GGUF"
  local gguf_filename="$2"   # e.g., "test-Q4_K_M.gguf"
  local blob_size="${3:-1024}"

  local hf_hub_dir="${HOME}/.cache/huggingface/hub"
  local cache_dir="${hf_hub_dir}/${model_dir_name}"
  local blob_dir="${cache_dir}/blobs"
  local snapshot_dir="${cache_dir}/snapshots/abc123"

  mkdir -p "$blob_dir" "$snapshot_dir"

  # Create a fake blob with deterministic name.
  local blob_hash
  blob_hash="sha256-$(printf '%s' "$gguf_filename" | shasum -a 256 | cut -d' ' -f1)"
  dd if=/dev/zero of="${blob_dir}/${blob_hash}" bs=1 count="$blob_size" 2>/dev/null

  # Create a symlink in the snapshot pointing to the blob.
  ln -sf "../../blobs/${blob_hash}" "${snapshot_dir}/${gguf_filename}"
}

test_list_shows_quant_variants() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--test-GGUF" "test-Q4_K_M.gguf" 2048
  create_gguf_fixture "models--demo--test-GGUF" "test-Q8_0.gguf" 4096

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list shows quant variants' "list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'demo/test-GGUF:Q4_K_M'; then
    fail 'list shows quant variants' "expected output to contain 'demo/test-GGUF:Q4_K_M', got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/test-GGUF:Q8_0'; then
    fail 'list shows quant variants' "expected output to contain 'demo/test-GGUF:Q8_0', got: $out"
    return
  fi

  pass 'list shows quant variants'
}

test_list_json_includes_quant() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--test-GGUF" "test-UD-Q6_K.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list --json includes quant field' "list --json failed: $(cat "$stderr_file")"
    return
  fi

  local quant_val
  quant_val="$(jq -r '.[0].quant' "$stdout_file")"
  if [[ "$quant_val" != "UD-Q6_K" ]]; then
    fail 'list --json includes quant field' "expected quant 'UD-Q6_K', got '$quant_val'"
    return
  fi

  pass 'list --json includes quant field'
}

test_list_quiet_includes_quant() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--test-GGUF" "test-Q4_K_M.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list --quiet shows model:quant' "list --quiet failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_eq "$out" 'demo/test-GGUF:Q4_K_M'; then
    fail 'list --quiet shows model:quant' "expected 'demo/test-GGUF:Q4_K_M', got '$out'"
    return
  fi

  pass 'list --quiet shows model:quant'
}

test_remove_specific_quant() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--test-GGUF" "test-Q4_K_M.gguf" 1024
  create_gguf_fixture "models--demo--test-GGUF" "test-Q8_0.gguf" 2048

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove 'demo/test-GGUF:Q4_K_M' --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove specific quant' "remove failed: $(cat "$stderr_file")"
    return
  fi

  local hf_hub_dir="${HOME}/.cache/huggingface/hub"
  local cache_dir="${hf_hub_dir}/models--demo--test-GGUF"

  # The Q4_K_M gguf should be gone.
  if ls "$cache_dir"/snapshots/*/test-Q4_K_M.gguf >/dev/null 2>&1; then
    fail 'remove specific quant' 'expected Q4_K_M gguf to be deleted'
    return
  fi

  # The Q8_0 gguf should still exist.
  if ! ls "$cache_dir"/snapshots/*/test-Q8_0.gguf >/dev/null 2>&1; then
    fail 'remove specific quant' 'expected Q8_0 gguf to still exist'
    return
  fi

  # The model cache directory should still exist.
  if [[ ! -d "$cache_dir" ]]; then
    fail 'remove specific quant' 'expected model cache dir to still exist'
    return
  fi

  pass 'remove specific quant'
}

test_remove_last_quant_cleans_dir() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--single-GGUF" "single-Q4_K_M.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove 'demo/single-GGUF:Q4_K_M' --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove last quant cleans model dir' "remove failed: $(cat "$stderr_file")"
    return
  fi

  local hf_hub_dir="${HOME}/.cache/huggingface/hub"
  if [[ -d "${hf_hub_dir}/models--demo--single-GGUF" ]]; then
    fail 'remove last quant cleans model dir' 'expected model dir to be cleaned up when last quant removed'
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'No remaining quants'; then
    fail 'remove last quant cleans model dir' 'expected message about no remaining quants'
    return
  fi

  pass 'remove last quant cleans model dir'
}

test_remove_missing_quant_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--test-GGUF" "test-Q4_K_M.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove 'demo/test-GGUF:Q8_0' --force
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'remove missing quant errors' 'expected remove of non-existent quant to fail'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" "no cached files matching quant"; then
    fail 'remove missing quant errors' "expected error about missing quant, got: $(cat "$stderr_file")"
    return
  fi

  pass 'remove missing quant errors'
}

main() {
  command -v jq >/dev/null 2>&1 || {
    echo 'jq is required to run smoke tests.' >&2
    exit 1
  }

  setup_test_env
  test_top_level_help
  test_argument_parsing_errors

  setup_test_env
  test_install_flow

  setup_test_env
  test_update_flow

  setup_test_env
  test_pull_noninteractive

  setup_test_env
  test_status_and_versions

  setup_test_env
  test_prune_and_uninstall

  setup_test_env
  test_remove_model_force

  setup_test_env
  test_run_and_serve_forwarding

  setup_test_env
  test_list_shows_quant_variants

  setup_test_env
  test_list_json_includes_quant

  setup_test_env
  test_list_quiet_includes_quant

  setup_test_env
  test_remove_specific_quant

  setup_test_env
  test_remove_last_quant_cleans_dir

  setup_test_env
  test_remove_missing_quant_errors

  printf '\n'
  printf 'Passed: %s\n' "$PASS_COUNT"

  if [[ $FAIL_COUNT -ne 0 ]]; then
    printf 'Failed: %s\n' "$FAIL_COUNT"
    exit 1
  fi

  printf 'Failed: 0\n'
}

main "$@"
