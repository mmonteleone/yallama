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

if [[ "$url" == *"huggingface.co/api/models"* ]]; then
  fixture="${YALLAMA_TEST_FIXTURES_DIR}/hf-search-results.json"
  if [[ -f "$fixture" ]]; then
    cat "$fixture"
  else
    printf '[]\n'
  fi
  exit 0
fi

echo "mock curl: unhandled URL $url" >&2
exit 1
EOF
  chmod +x "$path"
}

write_mock_open() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"${YALLAMA_TEST_LOG_DIR}/open.log"
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
  write_mock_open "${TEST_DIR}/bin/open"
  write_mock_open "${TEST_DIR}/bin/xdg-open"
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

# ── search tests ─────────────────────────────────────────────────────────────

write_hf_search_fixture() {
  local fixtures_dir="$1"
  cat >"${fixtures_dir}/hf-search-results.json" <<'EOF'
[
  {
    "modelId": "demo/gemma-GGUF",
    "downloads": 12345,
    "likes": 42,
    "siblings": [
      {"rfilename": "gemma-Q4_K_M.gguf"},
      {"rfilename": "gemma-Q8_0.gguf"},
      {"rfilename": "BF16/gemma-BF16-00001-of-00002.gguf"},
      {"rfilename": "README.md"}
    ]
  },
  {
    "modelId": "demo/gemma-small-GGUF",
    "downloads": 6789,
    "likes": 10,
    "siblings": [
      {"rfilename": "gemma-small-F16.gguf"}
    ]
  }
]
EOF
}

test_search_no_query_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search
  if [[ $RUN_STATUS -ne 0 ]]; then
    pass 'search without query exits non-zero'
  else
    fail 'search without query exits non-zero' 'expected non-zero exit when query is omitted'
  fi
}

test_search_returns_results() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search returns tabular results' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'MODEL'; then
    fail 'search returns tabular results' "expected column header 'MODEL', got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/gemma-GGUF'; then
    fail 'search returns tabular results' "expected 'demo/gemma-GGUF' in output, got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/gemma-small-GGUF'; then
    fail 'search returns tabular results' "expected 'demo/gemma-small-GGUF' in output, got: $out"
    return
  fi

  pass 'search returns tabular results'
}

test_search_quiet() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quiet prints only names' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'demo/gemma-GGUF'; then
    fail 'search --quiet prints only names' "expected model name in quiet output, got: $out"
    return
  fi

  if assert_contains "$out" 'MODEL'; then
    fail 'search --quiet prints only names' "unexpected column header in quiet output"
    return
  fi

  pass 'search --quiet prints only names'
}

test_search_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --json output' "search failed: $(cat "$stderr_file")"
    return
  fi

  local name_val
  name_val="$(jq -r '.[0].name' "$stdout_file")"
  if [[ "$name_val" != 'demo/gemma-GGUF' ]]; then
    fail 'search --json output' "expected name 'demo/gemma-GGUF', got '$name_val'"
    return
  fi

  local dl_val
  dl_val="$(jq -r '.[0].downloads' "$stdout_file")"
  if [[ "$dl_val" != '12345' ]]; then
    fail 'search --json output' "expected downloads '12345', got '$dl_val'"
    return
  fi

  pass 'search --json output'
}

test_search_empty_results() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  # No fixture written — mock returns [] by default.

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search 'xyzzy-nonexistent'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search empty results' "search failed unexpectedly: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'No models found'; then
    fail 'search empty results' "expected 'No models found' message, got: $(cat "$stdout_file")"
    return
  fi

  pass 'search empty results'
}

test_search_empty_results_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search 'xyzzy-nonexistent' --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search empty results --json' "search failed: $(cat "$stderr_file")"
    return
  fi

  local val
  val="$(cat "$stdout_file" | tr -d '[:space:]')"
  if [[ "$val" != '[]' ]]; then
    fail 'search empty results --json' "expected '[]', got: $val"
    return
  fi

  pass 'search empty results --json'
}

test_search_sort_option() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  # Default sort should be trendingScore.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma
  if ! assert_contains "$(cat "${YALLAMA_TEST_LOG_DIR}/curl.log")" 'sort=trendingScore'; then
    fail 'search default sort is trending' "expected sort=trendingScore in request URL"
    return
  fi
  pass 'search default sort is trending'

  # --sort downloads should pass sort=downloads to the API.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --sort downloads
  if ! assert_contains "$(cat "${YALLAMA_TEST_LOG_DIR}/curl.log")" 'sort=downloads'; then
    fail 'search --sort downloads' "expected sort=downloads in request URL"
    return
  fi
  pass 'search --sort downloads'

  # --sort newest should map to lastModified in the URL.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --sort newest
  if ! assert_contains "$(cat "${YALLAMA_TEST_LOG_DIR}/curl.log")" 'sort=lastModified'; then
    fail 'search --sort newest maps to lastModified' "expected sort=lastModified in request URL"
    return
  fi
  pass 'search --sort newest maps to lastModified'

  # Invalid sort value should error.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --sort bogus
  if [[ $RUN_STATUS -ne 0 ]] && assert_contains "$(cat "$stderr_file")" 'unknown sort value'; then
    pass 'search --sort rejects invalid value'
  else
    fail 'search --sort rejects invalid value' "expected non-zero exit and error for unknown sort"
  fi
}

test_search_quants_tabular() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants tabular output' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'Q4_K_M'; then
    fail 'search --quants tabular output' "expected quant 'Q4_K_M' in output, got: $out"
    return
  fi

  if ! assert_contains "$out" 'Q8_0'; then
    fail 'search --quants tabular output' "expected quant 'Q8_0' in output, got: $out"
    return
  fi

  if ! assert_contains "$out" 'BF16'; then
    fail 'search --quants tabular output' "expected quant 'BF16' in output (from subdirectory file), got: $out"
    return
  fi

  if ! assert_contains "$out" 'F16'; then
    fail 'search --quants tabular output' "expected quant 'F16' for second model, got: $out"
    return
  fi

  pass 'search --quants tabular output'
}

test_search_quants_quiet() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants --quiet prints MODEL:QUANT lines' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'demo/gemma-GGUF:Q4_K_M'; then
    fail 'search --quants --quiet prints MODEL:QUANT lines' "expected 'demo/gemma-GGUF:Q4_K_M', got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/gemma-small-GGUF:F16'; then
    fail 'search --quants --quiet prints MODEL:QUANT lines' "expected 'demo/gemma-small-GGUF:F16', got: $out"
    return
  fi

  pass 'search --quants --quiet prints MODEL:QUANT lines'
}

test_search_quants_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants --json quants sorted by bit depth' "search failed: $(cat "$stderr_file")"
    return
  fi

  # BF16 (16-bit) should sort before Q8_0 (8-bit) before Q4_K_M (4-bit).
  local quants
  quants="$(jq -r '.[0].quants | join(",")' "$stdout_file")"
  local bf16_pos q8_pos q4_pos
  bf16_pos="$(jq -r '.[0].quants | index("BF16")' "$stdout_file")"
  q8_pos="$(jq -r '.[0].quants | index("Q8_0")' "$stdout_file")"
  q4_pos="$(jq -r '.[0].quants | index("Q4_K_M")' "$stdout_file")"

  if [[ "$bf16_pos" -ge "$q8_pos" || "$q8_pos" -ge "$q4_pos" ]]; then
    fail 'search --quants --json quants sorted by bit depth' \
      "expected BF16($bf16_pos) < Q8_0($q8_pos) < Q4_K_M($q4_pos) in: $quants"
    return
  fi

  pass 'search --quants --json quants sorted by bit depth'
}

test_search_default_quant_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants --json default_quant field' "search failed: $(cat "$stderr_file")"
    return
  fi

  # demo/gemma-GGUF has Q4_K_M — llama.cpp picks Q4_K_M first.
  local dq
  dq="$(jq -r '.[0].default_quant' "$stdout_file")"
  if ! assert_eq "$dq" 'Q4_K_M'; then
    fail 'search --quants --json default_quant field' "expected Q4_K_M, got: $dq"
    return
  fi

  # demo/gemma-small-GGUF has only F16 — fallback to first GGUF alphabetically.
  local dq2
  dq2="$(jq -r '.[1].default_quant' "$stdout_file")"
  if ! assert_eq "$dq2" 'F16'; then
    fail 'search --quants --json default_quant field' "expected F16 for small model, got: $dq2"
    return
  fi

  pass 'search --quants --json default_quant field'
}

test_search_default_quant_tabular() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$YALLAMA_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants tabular marks default quant' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" '*Q4_K_M'; then
    fail 'search --quants tabular marks default quant' "expected '*Q4_K_M' marker in output, got: $out"
    return
  fi

  pass 'search --quants tabular marks default quant'
}

test_browse_opens_url() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" browse 'demo/test-model'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'browse opens correct URL' "browse failed: $(cat "$stderr_file")"
    return
  fi

  local open_log="${YALLAMA_TEST_LOG_DIR}/open.log"
  if ! assert_contains "$(cat "$open_log" 2>/dev/null)" 'https://huggingface.co/demo/test-model'; then
    fail 'browse opens correct URL' "expected HF URL in open log, got: $(cat "$open_log" 2>/dev/null)"
    return
  fi

  pass 'browse opens correct URL'
}

test_browse_print_flag() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" browse 'demo/test-model' --print
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'browse --print outputs URL' "browse failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_eq "$out" 'https://huggingface.co/demo/test-model'; then
    fail 'browse --print outputs URL' "expected HF URL, got: $out"
    return
  fi

  pass 'browse --print outputs URL'
}

test_browse_strips_quant() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" browse 'demo/test-model:Q4_K_M' --print
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'browse strips quant from URL' "browse failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_eq "$out" 'https://huggingface.co/demo/test-model'; then
    fail 'browse strips quant from URL' "expected URL without quant, got: $out"
    return
  fi

  pass 'browse strips quant from URL'
}

test_browse_no_model_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" browse
  if [[ $RUN_STATUS -ne 0 ]]; then
    pass 'browse without model exits non-zero'
  else
    fail 'browse without model exits non-zero' 'expected non-zero exit when model is omitted'
  fi
}

test_search_bad_argument_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --bogus
  if [[ $RUN_STATUS -ne 0 ]] && assert_contains "$(cat "$stderr_file")" 'Unknown argument'; then
    pass 'search rejects unknown arguments'
  else
    fail 'search rejects unknown arguments' "expected non-zero exit and error message"
  fi
}

# ── profile tests ─────────────────────────────────────────────────────────────

test_profile_set_and_show() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 --n-predict 4096 --temp 0.2 -ngl 99

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set creates profile file' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Profile 'coder' saved."; then
    fail 'profile set creates profile file' "expected success message, got: $(cat "$stdout_file")"
    return
  fi

  local profile_file="${YALLAMA_PROFILES_DIR}/coder"
  if [[ ! -f "$profile_file" ]]; then
    fail 'profile set creates profile file' "expected profile file at $profile_file"
    return
  fi

  if ! assert_contains "$(cat "$profile_file")" 'model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'; then
    fail 'profile set creates profile file' "expected model= line in profile"
    return
  fi

  if ! assert_contains "$(cat "$profile_file")" '--ctx-size'; then
    fail 'profile set creates profile file' "expected flags in profile"
    return
  fi

  pass 'profile set creates profile file'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile show prints profile' "profile show failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'; then
    fail 'profile show prints profile' "expected model line in show output"
    return
  fi

  pass 'profile show prints profile'
}

test_profile_list() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set writer \
    'unsloth/llama-3-8B-it-GGUF:Q4_K_M'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile list
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile list shows all profiles' "profile list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'coder'; then
    fail 'profile list shows all profiles' "expected 'coder' in list, got: $out"
    return
  fi

  if ! assert_contains "$out" 'writer'; then
    fail 'profile list shows all profiles' "expected 'writer' in list, got: $out"
    return
  fi

  pass 'profile list shows all profiles'
}

test_profile_list_empty() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles-empty"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile list
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile list empty is not an error' "profile list failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'No profiles found'; then
    fail 'profile list empty is not an error' "expected 'No profiles found', got: $(cat "$stdout_file")"
    return
  fi

  pass 'profile list empty is not an error'
}

test_profile_remove() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile remove coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile remove deletes profile' "profile remove failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -f "${YALLAMA_PROFILES_DIR}/coder" ]]; then
    fail 'profile remove deletes profile' "expected profile file to be gone"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Profile 'coder' removed."; then
    fail 'profile remove deletes profile' "expected removal confirmation"
    return
  fi

  pass 'profile remove deletes profile'
}

test_profile_remove_missing_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile remove nonexistent
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile remove missing profile errors' 'expected non-zero exit'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" "not found"; then
    fail 'profile remove missing profile errors' "expected 'not found' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile remove missing profile errors'
}

test_profile_duplicate() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 65536 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile duplicate coder coder-hi-ctx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile duplicate copies profile' "profile duplicate failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${YALLAMA_PROFILES_DIR}/coder-hi-ctx" ]]; then
    fail 'profile duplicate copies profile' "expected destination profile file to exist"
    return
  fi

  if ! diff -q "${YALLAMA_PROFILES_DIR}/coder" "${YALLAMA_PROFILES_DIR}/coder-hi-ctx" >/dev/null 2>&1; then
    fail 'profile duplicate copies profile' "expected source and destination to have identical contents"
    return
  fi

  pass 'profile duplicate copies profile'
}

test_profile_duplicate_dest_exists_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder2 \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q4_K_XL'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile duplicate coder coder2
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile duplicate refuses overwrite' 'expected non-zero exit when destination exists'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'already exists'; then
    fail 'profile duplicate refuses overwrite' "expected 'already exists' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile duplicate refuses overwrite'
}

test_profile_invalid_name_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set 'bad name' 'demo/model'
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile set rejects invalid name' 'expected non-zero exit for name with space'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'invalid profile name'; then
    fail 'profile set rejects invalid name' "expected 'invalid profile name' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile set rejects invalid name'
}

test_profile_overwrite() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 32768
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 65536

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set overwrites existing' "second set failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "${YALLAMA_PROFILES_DIR}/coder")" '--ctx-size'; then
    fail 'profile set overwrites existing' "expected flags in overwritten profile"
    return
  fi

  # The old value 32768 should not appear; 65536 should.
  if assert_contains "$(cat "${YALLAMA_PROFILES_DIR}/coder")" '32768'; then
    fail 'profile set overwrites existing' "expected old ctx-size 32768 to be gone after overwrite"
    return
  fi

  pass 'profile set overwrites existing'
}

test_run_with_profile() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_args_log="${TEST_DIR}/run-args.log"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  export YALLAMA_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$YALLAMA_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"
  export YALLAMA_RUN_ARGS_LOG="$run_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 --temp 0.2 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'run with profile resolves model and flags' "run coder failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$run_args_log")"

  if ! assert_contains "$args" '-hf unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'; then
    fail 'run with profile resolves model and flags' "expected model spec in args, got: $args"
    return
  fi

  if ! assert_contains "$args" '--ctx-size'; then
    fail 'run with profile resolves model and flags' "expected --ctx-size in args, got: $args"
    return
  fi

  if ! assert_contains "$args" '-ngl 99'; then
    fail 'run with profile resolves model and flags' "expected -ngl 99 in args, got: $args"
    return
  fi

  pass 'run with profile resolves model and flags'
}

test_serve_with_profile() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local serve_args_log="${TEST_DIR}/serve-args.log"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  export YALLAMA_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$YALLAMA_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"
  export YALLAMA_SERVE_ARGS_LOG="$serve_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 --temp 0.2 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'serve with profile resolves model and flags' "serve coder failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$serve_args_log")"

  if ! assert_contains "$args" '-hf unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL'; then
    fail 'serve with profile resolves model and flags' "expected model spec in args, got: $args"
    return
  fi

  if ! assert_contains "$args" '--jinja'; then
    fail 'serve with profile resolves model and flags' "expected --jinja in args, got: $args"
    return
  fi

  if ! assert_contains "$args" '--ctx-size'; then
    fail 'serve with profile resolves model and flags' "expected --ctx-size in args, got: $args"
    return
  fi

  pass 'serve with profile resolves model and flags'
}

test_serve_with_profile_and_extra_args() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local serve_args_log="${TEST_DIR}/serve-args.log"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  export YALLAMA_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$YALLAMA_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"
  export YALLAMA_SERVE_ARGS_LOG="$serve_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve coder -- --port 8081
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'serve with profile appends extra args' "serve coder -- --port 8081 failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$serve_args_log")"

  if ! assert_contains "$args" '--port 8081'; then
    fail 'serve with profile appends extra args' "expected --port 8081 in args, got: $args"
    return
  fi

  if ! assert_contains "$args" '--ctx-size'; then
    fail 'serve with profile appends extra args' "expected profile --ctx-size still present, got: $args"
    return
  fi

  pass 'serve with profile appends extra args'
}

test_run_missing_profile_errors() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles-empty"
  export YALLAMA_INSTALL_ROOT="$install_root"
  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run nonexistent-profile
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'run with missing profile errors' 'expected non-zero exit'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'not found'; then
    fail 'run with missing profile errors' "expected 'not found' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'run with missing profile errors'
}

test_profile_command_sections() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_args_log="${TEST_DIR}/run-args.log"
  local serve_args_log="${TEST_DIR}/serve-args.log"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  export YALLAMA_INSTALL_ROOT="$install_root"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$YALLAMA_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$YALLAMA_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"

  export YALLAMA_RUN_ARGS_LOG="$run_args_log"
  export YALLAMA_SERVE_ARGS_LOG="$serve_args_log"

  # Write a profile with common flags and per-command sections.
  mkdir -p "$YALLAMA_PROFILES_DIR"
  cat >"${YALLAMA_PROFILES_DIR}/coder" <<'PROFILE'
model=demo/model:Q4_K
--temp 0.2
-ngl 99
[serve]
--ctx-size 65536
--cache-reuse 256
[run]
--ctx-size 32768
PROFILE

  # serve: should include common + [serve] flags, not [run] flags.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile [serve] section included for serve' "serve coder failed: $(cat "$stderr_file")"
    return
  fi

  local sargs
  sargs="$(cat "$serve_args_log")"

  if ! assert_contains "$sargs" '--temp 0.2'; then
    fail 'profile [serve] section included for serve' "expected common flag --temp in serve args, got: $sargs"
    return
  fi

  if ! assert_contains "$sargs" '--cache-reuse'; then
    fail 'profile [serve] section included for serve' "expected [serve] flag --cache-reuse in serve args, got: $sargs"
    return
  fi

  if assert_contains "$sargs" '32768'; then
    fail 'profile [serve] section excluded for serve' "expected [run] flag --ctx-size 32768 NOT in serve args, got: $sargs"
    return
  fi

  pass 'profile [serve] section included for serve'
  pass 'profile [serve] section excluded for serve'

  # run: should include common + [run] flags, not [serve] flags.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile [run] section included for run' "run coder failed: $(cat "$stderr_file")"
    return
  fi

  local rargs
  rargs="$(cat "$run_args_log")"

  if ! assert_contains "$rargs" '--temp 0.2'; then
    fail 'profile [run] section included for run' "expected common flag --temp in run args, got: $rargs"
    return
  fi

  if ! assert_contains "$rargs" '32768'; then
    fail 'profile [run] section included for run' "expected [run] flag --ctx-size 32768 in run args, got: $rargs"
    return
  fi

  if assert_contains "$rargs" '--cache-reuse'; then
    fail 'profile [run] section excluded for run' "expected [serve] flag --cache-reuse NOT in run args, got: $rargs"
    return
  fi

  pass 'profile [run] section included for run'
  pass 'profile [run] section excluded for run'
}

test_profile_new_builtin_with_model() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  unset YALLAMA_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new mycoder code user/qwen2.5:Q4_K
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile new from builtin with model' "command failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "created from template"; then
    fail 'profile new from builtin with model' "expected success message, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show mycoder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile new from builtin with model' "show failed: $(cat "$stderr_file")"
    return
  fi

  local content
  content="$(cat "$stdout_file")"
  if ! assert_contains "$content" "model=user/qwen2.5:Q4_K"; then
    fail 'profile new from builtin with model' "expected model line, got: $content"
    return
  fi
  if ! assert_contains "$content" "--temp 0.2"; then
    fail 'profile new from builtin with model' "expected code template flag --temp, got: $content"
    return
  fi
  if ! assert_contains "$content" "-ngl 999"; then
    fail 'profile new from builtin with model' "expected code template flag -ngl, got: $content"
    return
  fi

  pass 'profile new from builtin with model'
}

test_profile_new_builtin_no_model_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  unset YALLAMA_TEMPLATES_DIR

  # 'code' built-in has no model= line; no model arg provided → should error.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new mycoder code
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile new builtin no model errors' "expected failure when no model provided"
    return
  fi
  if ! assert_contains "$(cat "$stderr_file")" "no model specified"; then
    fail 'profile new builtin no model errors' "expected 'no model specified' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile new builtin no model errors'
}

test_profile_new_user_template() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  export YALLAMA_TEMPLATES_DIR="${HOME}/.config/yallama/templates"

  # Create a user-defined template with a default model.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-set mytemplate user/mymodel:Q4_K -- --temp 0.5 --ctx-size 4096
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile new from user template' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  # Create a profile from it (no model arg — should use template's default).
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new myprofile mytemplate
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile new from user template' "profile new failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show myprofile
  local content
  content="$(cat "$stdout_file")"
  if ! assert_contains "$content" "model=user/mymodel:Q4_K"; then
    fail 'profile new from user template' "expected default model from template, got: $content"
    return
  fi
  if ! assert_contains "$content" "--temp 0.5"; then
    fail 'profile new from user template' "expected template flag --temp, got: $content"
    return
  fi

  pass 'profile new from user template'
}

test_profile_new_overwrite_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_PROFILES_DIR="${HOME}/.config/yallama/profiles"
  unset YALLAMA_TEMPLATES_DIR

  # Create it once.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new mypro code user/model
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile new overwrite errors' "first create failed: $(cat "$stderr_file")"
    return
  fi

  # Try to create again — should fail.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new mypro code user/model
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile new overwrite errors' "expected failure when profile already exists"
    return
  fi
  if ! assert_contains "$(cat "$stderr_file")" "already exists"; then
    fail 'profile new overwrite errors' "expected 'already exists' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile new overwrite errors'
}

test_profile_templates_lists_builtins() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  unset YALLAMA_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile templates
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile templates lists builtins' "command failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  for tname in chat code; do
    if ! assert_contains "$out" "$tname"; then
      fail 'profile templates lists builtins' "expected '$tname' in output, got: $out"
      return
    fi
  done
  if ! assert_contains "$out" "built-in"; then
    fail 'profile templates lists builtins' "expected 'built-in' label in output, got: $out"
    return
  fi

  pass 'profile templates lists builtins'
}

test_profile_template_show_builtin() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  unset YALLAMA_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-show code
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile template-show builtin' "command failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" "--temp 0.2"; then
    fail 'profile template-show builtin' "expected '--temp 0.2' in code template, got: $out"
    return
  fi
  if ! assert_contains "$out" "-ngl 999"; then
    fail 'profile template-show builtin' "expected '-ngl 999' in code template, got: $out"
    return
  fi

  pass 'profile template-show builtin'
}

test_profile_template_set_and_show() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_TEMPLATES_DIR="${HOME}/.config/yallama/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-set mywork user/work-model -- --temp 0.3 --ctx-size 8192
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile template-set and show' "template-set failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "saved"; then
    fail 'profile template-set and show' "expected 'saved' message, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-show mywork
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile template-set and show' "template-show failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" "model=user/work-model"; then
    fail 'profile template-set and show' "expected model line, got: $out"
    return
  fi
  if ! assert_contains "$out" "--temp 0.3"; then
    fail 'profile template-set and show' "expected --temp 0.3, got: $out"
    return
  fi

  pass 'profile template-set and show'
}

test_profile_template_remove() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_TEMPLATES_DIR="${HOME}/.config/yallama/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-set mytmp -- --temp 0.5
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile template-remove' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-remove mytmp
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile template-remove' "template-remove failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "removed"; then
    fail 'profile template-remove' "expected 'removed' message, got: $(cat "$stdout_file")"
    return
  fi

  # Subsequent show should fail.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-show mytmp
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile template-remove' "expected show to fail after removal"
    return
  fi

  pass 'profile template-remove'
}

test_profile_template_remove_builtin_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  unset YALLAMA_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-remove chat
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile template-remove builtin errors' "expected failure when removing built-in template"
    return
  fi
  if ! assert_contains "$(cat "$stderr_file")" "built-in"; then
    fail 'profile template-remove builtin errors' "expected 'built-in' in error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile template-remove builtin errors'
}

test_profile_template_user_overrides_builtin() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export YALLAMA_TEMPLATES_DIR="${HOME}/.config/yallama/templates"

  # Write a user template named 'code' that overrides the built-in.
  mkdir -p "$YALLAMA_TEMPLATES_DIR"
  cat >"${YALLAMA_TEMPLATES_DIR}/code" <<'EOF'
--temp 0.9
--ctx-size 1024
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile template-show code
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile user template overrides builtin' "template-show failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  # User file has --temp 0.9 (not 0.1 from built-in).
  if ! assert_contains "$out" "--temp 0.9"; then
    fail 'profile user template overrides builtin' "expected user template --temp 0.9, got: $out"
    return
  fi
  if assert_contains "$out" "--temp 0.1"; then
    fail 'profile user template overrides builtin' "expected built-in content to be shadowed, got: $out"
    return
  fi

  pass 'profile user template overrides builtin'
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

  setup_test_env
  test_search_no_query_errors

  setup_test_env
  test_search_returns_results

  setup_test_env
  test_search_quiet

  setup_test_env
  test_search_json

  setup_test_env
  test_search_empty_results

  setup_test_env
  test_search_empty_results_json

  setup_test_env
  test_search_sort_option

  setup_test_env
  test_search_quants_tabular

  setup_test_env
  test_search_quants_quiet

  setup_test_env
  test_search_quants_json

  setup_test_env
  test_search_default_quant_json

  setup_test_env
  test_search_default_quant_tabular

  setup_test_env
  test_browse_opens_url

  setup_test_env
  test_browse_print_flag

  setup_test_env
  test_browse_strips_quant

  setup_test_env
  test_browse_no_model_errors

  setup_test_env
  test_search_bad_argument_errors

  setup_test_env
  test_profile_set_and_show

  setup_test_env
  test_profile_list

  setup_test_env
  test_profile_list_empty

  setup_test_env
  test_profile_remove

  setup_test_env
  test_profile_remove_missing_errors

  setup_test_env
  test_profile_duplicate

  setup_test_env
  test_profile_duplicate_dest_exists_errors

  setup_test_env
  test_profile_invalid_name_errors

  setup_test_env
  test_profile_overwrite

  setup_test_env
  test_run_with_profile

  setup_test_env
  test_serve_with_profile

  setup_test_env
  test_serve_with_profile_and_extra_args

  setup_test_env
  test_run_missing_profile_errors

  setup_test_env
  test_profile_command_sections

  setup_test_env
  test_profile_new_builtin_with_model

  setup_test_env
  test_profile_new_builtin_no_model_errors

  setup_test_env
  test_profile_new_user_template

  setup_test_env
  test_profile_new_overwrite_errors

  setup_test_env
  test_profile_templates_lists_builtins

  setup_test_env
  test_profile_template_show_builtin

  setup_test_env
  test_profile_template_set_and_show

  setup_test_env
  test_profile_template_remove

  setup_test_env
  test_profile_template_remove_builtin_errors

  setup_test_env
  test_profile_template_user_overrides_builtin

  printf '\n'
  printf 'Passed: %s\n' "$PASS_COUNT"

  if [[ $FAIL_COUNT -ne 0 ]]; then
    printf 'Failed: %s\n' "$FAIL_COUNT"
    exit 1
  fi

  printf 'Failed: 0\n'
}

main "$@"
