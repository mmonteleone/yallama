#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="${ROOT_DIR}/src/corral.sh"
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

run_cmd_with_input() {
  local input="$1"
  local stdout_file="$2"
  local stderr_file="$3"
  shift 3

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file" <<<"$input"
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

printf '%s\n' "$url" >>"${CORRAL_TEST_LOG_DIR}/curl.log"

if [[ "$url" == *"/releases/latest" ]]; then
  tag="$(cat "${CORRAL_TEST_STATE_DIR}/latest-tag")"
  cat "${CORRAL_TEST_FIXTURES_DIR}/release-${tag}.json"
  exit 0
fi

if [[ "$url" == *"/releases/tags/"* ]]; then
  tag="${url##*/}"
  cat "${CORRAL_TEST_FIXTURES_DIR}/release-${tag}.json"
  exit 0
fi

if [[ "$url" == *"/downloads/"* ]]; then
  asset_name="${url##*/}"
  cp "${CORRAL_TEST_FIXTURES_DIR}/${asset_name}" "$output"
  exit 0
fi

if [[ "$url" == *"huggingface.co/api/models"* ]]; then
  fixture="${CORRAL_TEST_FIXTURES_DIR}/hf-search-results.json"
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
printf '%s\n' "$1" >>"${CORRAL_TEST_LOG_DIR}/open.log"
EOF
  chmod +x "$path"
}

write_mock_exec_tool() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$(basename "$0")" "$*" >>"${CORRAL_TEST_LOG_DIR}/launch.log"
EOF
  chmod +x "$path"
}

write_mock_brew() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${CORRAL_BREW_LOG}"

if [[ "$1" == "install" && "$2" == "uv" ]]; then
  cat >"${CORRAL_TEST_UV_PATH}" <<'UVEOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CORRAL_UV_LOG}"
exit 0
UVEOF
  chmod +x "${CORRAL_TEST_UV_PATH}"
  exit 0
fi

echo "mock brew: unsupported args: $*" >&2
exit 1
EOF
  chmod +x "$path"
}

write_mock_ps() {
  local path="$1"
  cat >"$path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"pid=,comm=,args="* ]]; then
  cat <<'OUT'
26366 awk awk { # llama-server and mlx_lm.server default to port 8080 when --port is not explicitly given; if ($i == "-p") port = "is" }
31111 llama-server /tmp/install/current/llama-server -hf demo/server-model --port 9000
32222 llama-cli /tmp/install/current/llama-cli -hf demo/cli-model
33332 Python /opt/homebrew/bin/python /opt/homebrew/bin/mlx_lm.chat --model mlx-community/Qwen2.5-7B-Instruct-4bit
33333 mlx_lm.server /opt/homebrew/bin/mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit --port 8082
OUT
  exit 0
fi

echo "mock ps: unsupported args: $*" >&2
exit 1
EOF
  chmod +x "$path"
}

write_mock_uname() {
  local target="$1"
  local os_name="$2"
  local machine="$3"
  cat >"$target" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  -s) echo "$os_name" ;;
  -m) echo "$machine" ;;
  *)  echo "$os_name" ;;
esac
EOF
  chmod +x "$target"
}

test_generated_standalone_script() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local generated_script="${TEST_DIR}/corral-standalone"

  run_cmd "$stdout_file" "$stderr_file" bash "${ROOT_DIR}/tools/build.sh" --output "$generated_script"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'generated standalone script builds' "expected build to succeed: $(cat "$stderr_file")"
    return
  fi

  # shellcheck disable=SC2016  # single-quoted grep pattern is intentional literal
  if grep -q 'source "${SCRIPT_DIR}/lib/' "$generated_script"; then
    fail 'generated standalone script is self-contained' 'expected generated script to inline module code instead of sourcing src/lib/*.sh'
    return
  fi

  if grep -q 'template_dir="$(cd "$(dirname "${BASH_SOURCE\[0\]}")" && pwd)/../launch-templates"' "$generated_script"; then
    fail 'generated standalone script inlines launch templates' 'expected launch template loader to be inlined in the standalone script'
    return
  fi

  if ! grep -q 'pi-settings)' "$generated_script"; then
    fail 'generated standalone script inlines launch templates' 'expected standalone script to include embedded launch template cases'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$generated_script" help
  if [[ $RUN_STATUS -eq 0 ]] && assert_contains "$(cat "$stdout_file")" 'Commands:'; then
    pass 'generated standalone script builds'
    pass 'generated standalone script is self-contained'
    pass 'generated standalone script inlines launch templates'
  else
    fail 'generated standalone script is self-contained' "expected generated script to run standalone help successfully: $(cat "$stderr_file")"
  fi
}

setup_test_env() {
  TEST_DIR="$(mktemp -d "${TEST_ROOT}/case.XXXXXX")"
  export HOME="${TEST_DIR}/home"
  export CORRAL_TEST_FIXTURES_DIR="${TEST_DIR}/fixtures"
  export CORRAL_TEST_STATE_DIR="${TEST_DIR}/state"
  export CORRAL_TEST_LOG_DIR="${TEST_DIR}/logs"
  export PATH="${TEST_DIR}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export SHELL="/bin/bash"
  unset CORRAL_PROFILES_DIR
  unset CORRAL_TEMPLATES_DIR
  unset XDG_CONFIG_HOME
  unset ZDOTDIR

  mkdir -p "$HOME" "$CORRAL_TEST_FIXTURES_DIR" "$CORRAL_TEST_STATE_DIR" "$CORRAL_TEST_LOG_DIR" "${TEST_DIR}/bin"
  write_mock_curl "${TEST_DIR}/bin/curl"
  write_mock_open "${TEST_DIR}/bin/open"
  write_mock_open "${TEST_DIR}/bin/xdg-open"
  # Default to a non-arm64 platform so llama.cpp is the resolved backend in
  # tests that do not explicitly mock uname for an arm64/MLX path.
  write_mock_uname "${TEST_DIR}/bin/uname" "Linux" "x86_64"
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
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

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

  if ! assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/curl.log")" "llama-b1000-bin-${arch}.tar.gz"; then
    fail 'arch detection in install flow' 'expected asset download to match detected architecture'
    return
  fi

  pass 'mocked install flow'
  pass 'arch detection in install flow'
}

test_install_rewrites_stale_bash_path_block() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local bashrc="${HOME}/.bashrc"
  local bashrc_contents

  export SHELL="/bin/bash"

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  cat >"$bashrc" <<'EOF'
# keep-before
# BEGIN corral
export PATH="/stale/path:$PATH"
# END corral
# keep-after
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'install rewrites stale bash PATH block' "install failed: $(cat "$stderr_file")"
    return
  fi

  bashrc_contents="$(cat "$bashrc")"
  if ! assert_contains "$bashrc_contents" "export PATH=\"${install_root}/current:\$PATH\""; then
    fail 'install rewrites stale bash PATH block' "expected updated PATH block, got: $bashrc_contents"
    return
  fi

  if assert_contains "$bashrc_contents" '/stale/path'; then
    fail 'install removes stale bash PATH entry' "did not expect stale PATH entry after install: $bashrc_contents"
    return
  fi

  if ! assert_contains "$bashrc_contents" '# keep-before' || ! assert_contains "$bashrc_contents" '# keep-after'; then
    fail 'install preserves surrounding bash config' "expected surrounding bash config to remain, got: $bashrc_contents"
    return
  fi

  pass 'install rewrites stale bash PATH block'
  pass 'install removes stale bash PATH entry'
  pass 'install preserves surrounding bash config'
}

test_install_creates_bash_completion_loader_when_bashrc_missing() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local bashrc="${HOME}/.bashrc"
  local bashrc_contents

  export SHELL="/bin/bash"

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  rm -f "$bashrc"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'install creates bash completion loader when bashrc is missing' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "$bashrc" ]]; then
    fail 'install creates bash completion loader when bashrc is missing' 'expected install to create ~/.bashrc'
    return
  fi

  if [[ ! -f "${HOME}/.bash_completion.d/corral" ]]; then
    fail 'install writes bash completion file' 'expected bash completion file to be installed'
    return
  fi

  bashrc_contents="$(cat "$bashrc")"
  if ! assert_contains "$bashrc_contents" '# BEGIN corral bash completions'; then
    fail 'install creates bash completion loader when bashrc is missing' "expected bash completion block, got: $bashrc_contents"
    return
  fi

  if ! assert_contains "$bashrc_contents" "for f in ~/.bash_completion.d/*; do [[ -f \"\$f\" ]] && source \"\$f\"; done"; then
    fail 'install writes bash completion loader' "expected bash completion loader line, got: $bashrc_contents"
    return
  fi

  pass 'install creates bash completion loader when bashrc is missing'
  pass 'install writes bash completion file'
  pass 'install writes bash completion loader'
}

test_install_creates_zsh_completion_loader() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local zshrc="${HOME}/.zshrc"
  local zshfunc_dir="${HOME}/.zfunc"
  local zshrc_contents

  export SHELL="/bin/zsh"

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  rm -f "$zshrc"
  rm -rf "$zshfunc_dir"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'install creates zsh completion loader' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${zshfunc_dir}/_corral" ]]; then
    fail 'install writes zsh completion file' 'expected zsh completion file to be installed into ~/.zfunc'
    return
  fi

  if [[ ! -f "$zshrc" ]]; then
    fail 'install creates zshrc for completion loader' 'expected install to create ~/.zshrc'
    return
  fi

  zshrc_contents="$(cat "$zshrc")"
  if ! assert_contains "$zshrc_contents" '# BEGIN corral zsh completions'; then
    fail 'install creates zsh completion loader' "expected zsh completion block, got: $zshrc_contents"
    return
  fi

  if ! assert_contains "$zshrc_contents" "fpath=(\"${zshfunc_dir}\" \$fpath)"; then
    fail 'install prepends zsh completion dir to fpath' "expected fpath update in zshrc, got: $zshrc_contents"
    return
  fi

  if ! assert_contains "$zshrc_contents" 'autoload -Uz compinit' || ! assert_contains "$zshrc_contents" 'compinit'; then
    fail 'install ensures zsh compinit runs' "expected compinit bootstrap in zshrc, got: $zshrc_contents"
    return
  fi

  pass 'install creates zsh completion loader'
  pass 'install writes zsh completion file'
  pass 'install creates zshrc for completion loader'
  pass 'install prepends zsh completion dir to fpath'
  pass 'install ensures zsh compinit runs'
}

test_install_zsh_completions_respect_zdotdir() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local zdotdir="${HOME}/dot-zsh"
  local zshrc="${zdotdir}/.zshrc"
  local zshfunc_dir="${zdotdir}/.zfunc"
  local zshrc_contents

  export SHELL="/bin/zsh"
  export ZDOTDIR="$zdotdir"

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  rm -rf "$zdotdir"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'install respects ZDOTDIR for zsh completions' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${zshfunc_dir}/_corral" ]]; then
    fail 'install writes zsh completion file under ZDOTDIR' "expected zsh completion file under \$ZDOTDIR/.zfunc"
    return
  fi

  if [[ ! -f "$zshrc" ]]; then
    fail 'install writes zshrc under ZDOTDIR' 'expected zshrc to be written under ZDOTDIR'
    return
  fi

  zshrc_contents="$(cat "$zshrc")"
  if ! assert_contains "$zshrc_contents" "fpath=(\"${zshfunc_dir}\" \$fpath)"; then
    fail 'install uses ZDOTDIR zfunc path in zshrc' "expected ZDOTDIR-based fpath update, got: $zshrc_contents"
    return
  fi

  pass 'install respects ZDOTDIR for zsh completions'
  pass 'install writes zsh completion file under ZDOTDIR'
  pass 'install writes zshrc under ZDOTDIR'
  pass 'install uses ZDOTDIR zfunc path in zshrc'
}

test_update_flow() {
  local arch
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1001' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1001' "$arch"

  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mocked update flow' "initial install failed: $(cat "$stderr_file")"
    return
  fi

  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1001'
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

printf '%s\n' "$*" >"$CORRAL_LLAMA_CLI_ARGS_LOG"

if [[ -t 0 ]]; then
  echo 'stdin should not be attached to a terminal during pull' >&2
  exit 42
fi

if read -r _; then
  echo 'stdin should be EOF during pull' >&2
  exit 43
fi

mkdir -p "$CORRAL_EXPECTED_CACHE_DIR"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  export CORRAL_INSTALL_ROOT="$install_root"
  export CORRAL_EXPECTED_CACHE_DIR="$expected_cache_dir"
  export CORRAL_LLAMA_CLI_ARGS_LOG="$args_log"

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

test_pull_explicit_llama_backend_override() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local args_log="${TEST_DIR}/llama-cli-args.log"
  local model_name='demo/test-model'
  local expected_cache_dir="${HOME}/.cache/huggingface/hub/models--demo--test-model"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  mkdir -p "$current_link" "$(dirname "$expected_cache_dir")"
  : >"$args_log"

  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >"$CORRAL_LLAMA_CLI_ARGS_LOG"
mkdir -p "$CORRAL_EXPECTED_CACHE_DIR"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  export CORRAL_INSTALL_ROOT="$install_root"
  export CORRAL_EXPECTED_CACHE_DIR="$expected_cache_dir"
  export CORRAL_LLAMA_CLI_ARGS_LOG="$args_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull --backend llama.cpp "$model_name"

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'pull explicit llama.cpp override' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$args_log")" "-hf ${model_name}"; then
    fail 'pull explicit llama.cpp override' "expected llama-cli pull args, got: $(cat "$args_log")"
    return
  fi

  pass 'pull explicit llama.cpp override'
}

test_pull_quant_not_confused_by_other_cached_quant() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local args_log="${TEST_DIR}/llama-cli-args.log"
  local model_name='demo/test-GGUF'
  local model_spec='demo/test-GGUF:UD-Q4_K_M'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--demo--test-GGUF"

  mkdir -p "$current_link"
  : >"$args_log"

  # Pre-cache a different quant to reproduce false "already cached" behavior.
  create_gguf_fixture "models--demo--test-GGUF" "test-UD-Q6_K_XL.gguf" 1024

  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >"$CORRAL_LLAMA_CLI_ARGS_LOG"
mkdir -p "$CORRAL_EXPECTED_CACHE_DIR/snapshots/def456"
: >"$CORRAL_EXPECTED_CACHE_DIR/snapshots/def456/$CORRAL_NEW_QUANT_FILENAME"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  export CORRAL_INSTALL_ROOT="$install_root"
  export CORRAL_LLAMA_CLI_ARGS_LOG="$args_log"
  export CORRAL_EXPECTED_CACHE_DIR="$cache_dir"
  export CORRAL_NEW_QUANT_FILENAME='test-UD-Q4_K_M.gguf'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull "$model_spec"

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'pull quant ignores other cached quants' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if assert_contains "$(cat "$stdout_file")" 'Model already cached'; then
    fail 'pull quant ignores other cached quants' 'expected pull to fetch missing quant instead of reporting already cached'
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Done: ${model_spec}"; then
    fail 'pull quant ignores other cached quants' "expected success for requested quant, got: $(cat "$stdout_file")"
    return
  fi

  if ! assert_contains "$(cat "$args_log")" "-hf ${model_spec}"; then
    fail 'pull quant ignores other cached quants' 'expected pull to invoke llama-cli with requested model:quant'
    return
  fi

  if ! ls "$cache_dir"/snapshots/*/test-UD-Q4_K_M.gguf >/dev/null 2>&1; then
    fail 'pull quant ignores other cached quants' 'expected requested quant file to be present after pull'
    return
  fi

  pass 'pull quant ignores other cached quants'
}

test_status_and_versions() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local arch

  arch="$(expected_arch)"
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1002' "$arch"
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1002' "$arch"
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1002'

  mkdir -p "${install_root}/llama-b1000" "${install_root}/llama-b1001"
  ln -sfn "${install_root}/llama-b1001" "${install_root}/current"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --path "$install_root"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'status output for installed version' "status failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'llama.cpp : b1001'; then
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

  local versions_out
  versions_out="$(cat "$stdout_file")"
  if ! assert_contains "$versions_out" 'VERSION' || ! assert_contains "$versions_out" 'STATUS'; then
    fail 'versions output marks current' "expected tabular headings in versions output, got: $versions_out"
    return
  fi

  if ! assert_contains "$versions_out" 'b1001' || ! assert_contains "$versions_out" 'current'; then
    fail 'versions output marks current' 'expected versions output to mark the active version'
    return
  fi

  if ! assert_contains "$versions_out" 'b1000'; then
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
printf '%s\n' "$*" >"$CORRAL_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"

  export CORRAL_INSTALL_ROOT="$install_root"
  export CORRAL_RUN_ARGS_LOG="$run_args_log"
  export CORRAL_SERVE_ARGS_LOG="$serve_args_log"
  export HF_TOKEN='hf_test_token'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend llama.cpp demo/run-model -- --threads 4
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'run forwards model and extra args' "run failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$run_args_log")" '-hf demo/run-model --hf-token hf_test_token --threads 4'; then
    fail 'run forwards model and extra args' 'expected run to forward model, hf token, and extra args to llama-cli'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve --backend llama.cpp demo/serve-model -- --port 8081
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

test_launch_requires_port_when_multiple_servers() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_ps "${TEST_DIR}/bin/ps"
  write_mock_exec_tool "${TEST_DIR}/bin/pi"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch pi

  if [[ $RUN_STATUS -ne 0 ]] && \
     assert_contains "$(cat "$stderr_file")" 'Multiple compatible corral servers are running' && \
     assert_contains "$(cat "$stderr_file")" '9000' && \
     assert_contains "$(cat "$stderr_file")" '8082'; then
    pass 'launch requires port when multiple compatible servers are running'
  else
    fail 'launch requires port when multiple compatible servers are running' "expected launch to reject ambiguous server selection: $(cat "$stderr_file")"
  fi
}

test_launch_pi_updates_configs_and_reuses_matching_config() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local agent_dir="${HOME}/.pi/agent"
  local settings_path="${agent_dir}/settings.json"
  local models_path="${agent_dir}/models.json"
  local backup_count_first backup_count_second

  write_mock_ps "${TEST_DIR}/bin/ps"
  write_mock_exec_tool "${TEST_DIR}/bin/pi"
  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'launch unexpectedly invoked python3' >&2
exit 99
EOF
  chmod +x "${TEST_DIR}/bin/python3"
  mkdir -p "$agent_dir"

  cat >"$settings_path" <<'EOF'
{
  "packages": {
    "allowed": [
      "ripgrep"
    ]
  },
  "defaultProvider": "other",
  "defaultModel": "other/model"
}
EOF

  cat >"$models_path" <<'EOF'
{
  "providers": {
    "existing": {
      "baseUrl": "https://example.invalid/v1",
      "api": "openai-completions",
      "models": [
        {
          "id": "example/model"
        }
      ]
    }
  }
}
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 8082 pi -- --resume last
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'launch pi updates config and launches tool' "launch pi failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$settings_path")" '"packages"' || \
     ! assert_contains "$(cat "$settings_path")" '"defaultProvider": "corral-launch"' || \
     ! assert_contains "$(cat "$settings_path")" '"defaultModel": "mlx-community/Qwen2.5-7B-Instruct-4bit"' || \
      ! assert_contains "$(cat "$models_path")" '"providers"' || \
     ! assert_contains "$(cat "$models_path")" '"existing"' || \
     ! assert_contains "$(cat "$models_path")" '"baseUrl": "http://127.0.0.1:8082/v1"' || \
      ! assert_contains "$(cat "$models_path")" '"id": "mlx-community/Qwen2.5-7B-Instruct-4bit"' || \
     ! assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/launch.log")" 'pi|--resume last'; then
    fail 'launch pi updates config and launches tool' 'expected pi launch to update settings/models and exec pi with passthrough args'
    return
  fi

  backup_count_first="$(find "$agent_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
  if [[ "$backup_count_first" != "2" ]]; then
    fail 'launch pi creates backups only for changed files' "expected 2 backup files after first pi launch, got ${backup_count_first}"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 8082 pi
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'launch pi reuses matching config without new backup' "second launch pi failed: $(cat "$stderr_file")"
    return
  fi

  backup_count_second="$(find "$agent_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
  if [[ "$backup_count_second" == "$backup_count_first" ]] && \
     assert_contains "$(cat "$stdout_file")" 'Config already matched'; then
    pass 'launch pi updates config and launches tool'
    pass 'launch pi creates backups only for changed files'
  else
    fail 'launch pi creates backups only for changed files' "expected backup count to remain ${backup_count_first}, got ${backup_count_second}"
  fi
}

test_launch_pi_backs_up_matching_preexisting_config_once() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local agent_dir="${HOME}/.pi/agent"
  local settings_path="${agent_dir}/settings.json"
  local models_path="${agent_dir}/models.json"
  local backup_count_first backup_count_second
  local settings_backup_count models_backup_count

  write_mock_ps "${TEST_DIR}/bin/ps"
  write_mock_exec_tool "${TEST_DIR}/bin/pi"
  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'launch unexpectedly invoked python3' >&2
exit 99
EOF
  chmod +x "${TEST_DIR}/bin/python3"
  mkdir -p "$agent_dir"

  cat >"$settings_path" <<'EOF'
{
  "defaultProvider": "corral-launch",
  "defaultModel": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "packages": {
    "allowed": [
      "ripgrep"
    ]
  }
}
EOF

  cat >"$models_path" <<'EOF'
{
  "providers": {
    "corral-launch": {
      "baseUrl": "http://127.0.0.1:8082/v1",
      "api": "openai-completions",
      "models": [
        {
          "id": "mlx-community/Qwen2.5-7B-Instruct-4bit"
        }
      ]
    }
  }
}
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 8082 pi
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'launch pi backs up matching pre-existing config once' "launch pi failed: $(cat "$stderr_file")"
    return
  fi

  backup_count_first="$(find "$agent_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
    settings_backup_count="$(find "$agent_dir" -name 'settings.json.bak.*' | wc -l | tr -d ' ')"
    models_backup_count="$(find "$agent_dir" -name 'models.json.bak.*' | wc -l | tr -d ' ')"
    if [[ "$backup_count_first" != "2" ]] || \
      [[ "$settings_backup_count" != "1" ]] || \
      [[ "$models_backup_count" != "1" ]] || \
     ! assert_contains "$(cat "$stdout_file")" 'Backed up' || \
     ! assert_contains "$(cat "$stdout_file")" 'Config already matched'; then
    fail 'launch pi backs up matching pre-existing config once' 'expected launch pi to preserve matching pre-existing config with one-time backups'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 8082 pi
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'launch pi does not duplicate backups for matching config' "second launch pi failed: $(cat "$stderr_file")"
    return
  fi

  backup_count_second="$(find "$agent_dir" -name '*.bak.*' | wc -l | tr -d ' ')"
  if [[ "$backup_count_second" == "$backup_count_first" ]]; then
    pass 'launch pi backs up matching pre-existing config once'
    pass 'launch pi does not duplicate backups for matching config'
  else
    fail 'launch pi does not duplicate backups for matching config' "expected backup count to remain ${backup_count_first}, got ${backup_count_second}"
  fi
}

test_launch_opencode_updates_jsonc_and_launches_tool() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local config_dir="${HOME}/.config/opencode"
  local config_path="${config_dir}/opencode.jsonc"

  write_mock_ps "${TEST_DIR}/bin/ps"
  write_mock_exec_tool "${TEST_DIR}/bin/opencode"
  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'launch unexpectedly invoked python3' >&2
exit 99
EOF
  chmod +x "${TEST_DIR}/bin/python3"
  mkdir -p "$config_dir"

  cat >"$config_path" <<'EOF'
{
  // existing config
  "theme": "nord",
  "provider": {
    "existing": {
      "npm": "example",
    },
  },
}
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 8082 opencode -- .
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'launch opencode updates jsonc and launches tool' "launch opencode failed: $(cat "$stderr_file")"
    return
  fi

  if assert_contains "$(cat "$config_path")" '"theme": "nord"' && \
     assert_contains "$(cat "$config_path")" '"corral-launch"' && \
     assert_contains "$(cat "$config_path")" '"model": "corral-launch/mlx-community/Qwen2.5-7B-Instruct-4bit"' && \
     assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/launch.log")" 'opencode|.'; then
    pass 'launch opencode updates jsonc and launches tool'
  else
    fail 'launch opencode updates jsonc and launches tool' "expected opencode launch to merge JSONC config and exec opencode; config=$(cat "$config_path" 2>/dev/null || echo missing), stdout=$(cat "$stdout_file" 2>/dev/null || echo empty), stderr=$(cat "$stderr_file" 2>/dev/null || echo empty), launch_log=$(cat "${CORRAL_TEST_LOG_DIR}/launch.log" 2>/dev/null || echo missing), XDG_CONFIG_HOME=${XDG_CONFIG_HOME-unset}"
  fi
}

test_launch_codex_is_unsupported() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_ps "${TEST_DIR}/bin/ps"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" launch --port 9000 codex

  if [[ $RUN_STATUS -ne 0 ]] && \
     assert_contains "$(cat "$stderr_file")" "unsupported launch target 'codex'"; then
    pass 'launch codex is unsupported'
  else
    fail 'launch codex is unsupported' "expected codex launch to be rejected as unsupported: $(cat "$stderr_file")"
  fi
}

test_mlx_install_uv_flow() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local uv_log="${TEST_DIR}/uv.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"
  cat >"${TEST_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CORRAL_UV_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/uv"
  export CORRAL_UV_LOG="$uv_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --backend mlx --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx install uses uv flow' "install --backend mlx failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$uv_log")" 'tool install mlx-lm'; then
    fail 'mlx install uses uv flow' "expected uv install call, got: $(cat "$uv_log")"
    return
  fi

  pass 'mlx install uses uv flow'
}

test_mlx_run_dispatches() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_log="${TEST_DIR}/mlx-run.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_RUN_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.chat"
  export CORRAL_MLX_RUN_LOG="$run_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend mlx demo/run-model -- --max-tokens 16
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx run dispatches to mlx_lm.chat' "run failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$run_log")" '--model demo/run-model --max-tokens 16'; then
    fail 'mlx run dispatches to mlx_lm.chat' "expected mlx_lm.chat args, got: $(cat "$run_log")"
    return
  fi

  pass 'mlx run dispatches to mlx_lm.chat'
}

test_mlx_serve_dispatches() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local serve_log="${TEST_DIR}/mlx-serve.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_SERVE_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.server"
  export CORRAL_MLX_SERVE_LOG="$serve_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve --backend mlx demo/serve-model -- --port 8899
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx serve dispatches to mlx_lm.server' "serve failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$serve_log")" '--model demo/serve-model --port 8899'; then
    fail 'mlx serve dispatches to mlx_lm.server' "expected mlx_lm.server args, got: $(cat "$serve_log")"
    return
  fi

  pass 'mlx serve dispatches to mlx_lm.server'
}

test_mlx_run_with_profile() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_log="${TEST_DIR}/mlx-run.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  mkdir -p "$CORRAL_PROFILES_DIR"
  cat >"${CORRAL_PROFILES_DIR}/coder" <<'EOF'
model=mlx-community/Qwen2.5-7B-Instruct-4bit
--temp 0.2
--max-tokens 64
EOF

  cat >"${TEST_DIR}/bin/mlx_lm.chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_RUN_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.chat"
  export CORRAL_MLX_RUN_LOG="$run_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx run infers backend from profile model' "run failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$run_log")"
  if ! assert_contains "$args" '--model mlx-community/Qwen2.5-7B-Instruct-4bit'; then
    fail 'mlx run infers backend from profile model' "expected model from profile, got: $args"
    return
  fi
  if ! assert_contains "$args" '--temp 0.2' || ! assert_contains "$args" '--max-tokens 64'; then
    fail 'mlx run infers backend from profile model' "expected flags from profile, got: $args"
    return
  fi

  pass 'mlx run infers backend from profile model'
}

test_mlx_run_profile_backend_sections() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_log="${TEST_DIR}/mlx-run.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  mkdir -p "$CORRAL_PROFILES_DIR"

  # Profile with common and backend-specific sections.
  cat >"${CORRAL_PROFILES_DIR}/mixed" <<'EOF'
model=mlx-community/Qwen2.5-7B-Instruct-4bit
--temp 0.2
[llama.cpp]
--flash-attn on
-ngl 999
[mlx.run]
--max-tokens 64
[llama.cpp.serve]
--cache-reuse 256
EOF

  cat >"${TEST_DIR}/bin/mlx_lm.chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_RUN_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.chat"
  export CORRAL_MLX_RUN_LOG="$run_log"

  # Ensure model exists in HF cache so backend infers mlx from cache.
  local mlx_cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"
  mkdir -p "${mlx_cache_dir}/snapshots/abc123"
  : >"${mlx_cache_dir}/snapshots/abc123/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run mixed
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx run loads backend-specific profile sections' "run failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$run_log")"
  # Common flag: should be present.
  if ! assert_contains "$args" '--temp 0.2'; then
    fail 'mlx run loads backend-specific profile sections' "expected common --temp, got: $args"
    return
  fi
  # [mlx.run]: should be present.
  if ! assert_contains "$args" '--max-tokens 64'; then
    fail 'mlx run loads backend-specific profile sections' "expected [mlx.run] flag, got: $args"
    return
  fi
  # [llama.cpp]: should be absent.
  if assert_contains "$args" '--flash-attn'; then
    fail 'mlx run excludes llama.cpp backend sections' "unexpected llama.cpp flag in: $args"
    return
  fi
  # [llama.cpp.serve]: should be absent.
  if assert_contains "$args" '--cache-reuse'; then
    fail 'mlx run excludes llama.cpp.serve section' "unexpected llama.cpp.serve flag in: $args"
    return
  fi

  pass 'mlx run loads backend-specific profile sections'
  pass 'mlx run excludes llama.cpp backend sections'
}

test_profile_set_from_template_preserves_backend_sections() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"
  mkdir -p "$CORRAL_TEMPLATES_DIR" "$CORRAL_PROFILES_DIR"

  # Create a user template with backend-specific sections.
  cat >"${CORRAL_TEMPLATES_DIR}/mixed" <<'EOF'
--temp 0.3
[llama.cpp]
--flash-attn on
-ngl 999
[mlx.run]
--max-tokens 128
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set testprof mixed some/model:Q4_K
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set from template preserves backend sections' "set failed: $(cat "$stderr_file")"
    return
  fi

  local profile_content
  profile_content="$(cat "${CORRAL_PROFILES_DIR}/testprof")"
  if ! assert_contains "$profile_content" 'model=some/model:Q4_K'; then
    fail 'profile set from template preserves backend sections' "expected model line, got: $profile_content"
    return
  fi
  if ! assert_contains "$profile_content" '[llama.cpp]'; then
    fail 'profile set from template preserves backend sections' "expected [llama.cpp] section, got: $profile_content"
    return
  fi
  if ! assert_contains "$profile_content" '[mlx.run]'; then
    fail 'profile set from template preserves backend sections' "expected [mlx.run] section, got: $profile_content"
    return
  fi
  if ! assert_contains "$profile_content" '--max-tokens 128'; then
    fail 'profile set from template preserves backend sections' "expected mlx flag, got: $profile_content"
    return
  fi

  pass 'profile set from template preserves backend sections'
}

test_template_backend_sections_inherited_by_profile() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  # Use the built-in 'code' template which now has [llama.cpp] and [llama.cpp.serve] sections.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set testcoder code demo/model:Q4_K
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template backend sections inherited by profile' "set failed: $(cat "$stderr_file")"
    return
  fi

  local profile_content
  profile_content="$(cat "${CORRAL_PROFILES_DIR}/testcoder")"
  if ! assert_contains "$profile_content" '[llama.cpp]'; then
    fail 'template backend sections inherited by profile' "expected [llama.cpp] section from code template, got: $profile_content"
    return
  fi
  if ! assert_contains "$profile_content" '--flash-attn on'; then
    fail 'template backend sections inherited by profile' "expected llama.cpp flag from code template, got: $profile_content"
    return
  fi

  pass 'template backend sections inherited by profile'
}

test_template_set_preserves_backend_sections() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"
  mkdir -p "$CORRAL_TEMPLATES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set mytemplate -- \
    --temp 0.5

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template set creates valid template' "set failed: $(cat "$stderr_file")"
    return
  fi

  local tmpl_content
  tmpl_content="$(cat "${CORRAL_TEMPLATES_DIR}/mytemplate")"
  if ! assert_contains "$tmpl_content" '--temp 0.5'; then
    fail 'template set creates valid template' "expected flag, got: $tmpl_content"
    return
  fi

  pass 'template set creates valid template'
}

test_mlx_serve_with_profile() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local serve_log="${TEST_DIR}/mlx-serve.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  mkdir -p "$CORRAL_PROFILES_DIR"
  cat >"${CORRAL_PROFILES_DIR}/coder" <<'EOF'
model=mlx-community/Qwen2.5-7B-Instruct-4bit
--temp 0.2
--port 8899
EOF

  cat >"${TEST_DIR}/bin/mlx_lm.server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_SERVE_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.server"
  export CORRAL_MLX_SERVE_LOG="$serve_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx serve infers backend from profile model' "serve failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$serve_log")"
  if ! assert_contains "$args" '--model mlx-community/Qwen2.5-7B-Instruct-4bit'; then
    fail 'mlx serve infers backend from profile model' "expected model from profile, got: $args"
    return
  fi

  if ! assert_contains "$args" '--temp 0.2' || ! assert_contains "$args" '--port 8899'; then
    fail 'mlx serve infers backend from profile model' "expected flags from profile, got: $args"
    return
  fi

  pass 'mlx serve infers backend from profile model'
}

test_llama_run_profile_backend_sections() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_args_log="${TEST_DIR}/run-args.log"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_INSTALL_ROOT="$install_root"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"
  export CORRAL_RUN_ARGS_LOG="$run_args_log"

  # Create a GGUF fixture so _infer_model_backend detects llama.cpp.
  create_gguf_fixture "models--demo--model-GGUF" "model-Q4_K.gguf"

  # Profile with backend-specific sections.
  mkdir -p "$CORRAL_PROFILES_DIR"
  cat >"${CORRAL_PROFILES_DIR}/lltest" <<'PROFILE'
model=demo/model-GGUF:Q4_K
--temp 0.2
[llama.cpp]
--flash-attn on
-ngl 999
[mlx]
--max-tokens 128
[llama.cpp.serve]
--cache-reuse 256
PROFILE

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run lltest
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'llama run loads backend-specific profile sections' "run failed: $(cat "$stderr_file")"
    return
  fi

  local args
  args="$(cat "$run_args_log")"
  if ! assert_contains "$args" '--temp 0.2'; then
    fail 'llama run loads backend-specific profile sections' "expected common flag, got: $args"
    return
  fi
  if ! assert_contains "$args" '--flash-attn on'; then
    fail 'llama run loads backend-specific profile sections' "expected [llama.cpp] flag, got: $args"
    return
  fi
  if assert_contains "$args" '--max-tokens'; then
    fail 'llama run excludes mlx backend sections' "unexpected mlx flag in: $args"
    return
  fi
  if assert_contains "$args" '--cache-reuse'; then
    fail 'llama run excludes llama.cpp.serve section' "unexpected serve flag in: $args"
    return
  fi

  pass 'llama run loads backend-specific profile sections'
  pass 'llama run excludes mlx backend sections'
}

test_mlx_quant_spec_warns() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local run_log="${TEST_DIR}/mlx-run.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_RUN_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.chat"
  export CORRAL_MLX_RUN_LOG="$run_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend mlx demo/run-model:Q4_K_M
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx run strips quant and warns' "run failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'does not use quant specifiers'; then
    fail 'mlx run strips quant and warns' "expected quant warning, got: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$run_log")" '--model demo/run-model'; then
    fail 'mlx run strips quant and warns' "expected model without quant, got: $(cat "$run_log")"
    return
  fi

  pass 'mlx run strips quant and warns'
}

test_mlx_pull_dispatches_generate() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local pull_log="${TEST_DIR}/mlx-pull.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_PULL_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"
  export CORRAL_MLX_PULL_LOG="$pull_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull mlx-community/Qwen2.5-7B-Instruct-4bit
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx pull dispatches to mlx_lm.generate' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$pull_log")" '--model mlx-community/Qwen2.5-7B-Instruct-4bit'; then
    fail 'mlx pull dispatches to mlx_lm.generate' "expected model arg, got: $(cat "$pull_log")"
    return
  fi

  if ! assert_contains "$(cat "$pull_log")" '--max-tokens 1'; then
    fail 'mlx pull dispatches to mlx_lm.generate' "expected max-tokens warm-up arg, got: $(cat "$pull_log")"
    return
  fi

  pass 'mlx pull dispatches to mlx_lm.generate'
}

test_mlx_pull_quant_spec_warns() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local pull_log="${TEST_DIR}/mlx-pull.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_PULL_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"
  export CORRAL_MLX_PULL_LOG="$pull_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull --backend mlx mlx-community/Qwen2.5-7B-Instruct-4bit:Q4_K_M
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx pull strips quant and warns' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'does not use quant specifiers'; then
    fail 'mlx pull strips quant and warns' "expected quant warning, got: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$pull_log")" '--model mlx-community/Qwen2.5-7B-Instruct-4bit'; then
    fail 'mlx pull strips quant and warns' "expected stripped model id, got: $(cat "$pull_log")"
    return
  fi

  if assert_contains "$(cat "$pull_log")" ':Q4_K_M'; then
    fail 'mlx pull strips quant and warns' "did not expect quant suffix in mlx_lm.generate args: $(cat "$pull_log")"
    return
  fi

  pass 'mlx pull strips quant and warns'
}

test_mlx_list_shows_cached_models() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local pull_log="${TEST_DIR}/mlx-pull.log"
  local model_name='mlx-community/Qwen2.5-7B-Instruct-4bit'

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_MLX_PULL_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"
  export CORRAL_MLX_PULL_LOG="$pull_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull "$model_name"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx list reads cached mlx models' "mlx pull failed: $(cat "$stderr_file")"
    return
  fi

  # Build a deterministic cache fixture; mocked mlx_lm.generate does not write
  # HF cache files in tests.
  local cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"
  mkdir -p "${cache_dir}/snapshots/abc123"
  : >"${cache_dir}/snapshots/abc123/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --backend mlx --quiet --models
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx list reads cached mlx models' "list failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "$model_name"; then
    fail 'mlx list reads cached mlx models' "expected model in mlx list output, got: $(cat "$stdout_file")"
    return
  fi

  pass 'mlx list reads cached mlx models'
}

test_mlx_remove_deletes_cache() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='mlx-community/Qwen2.5-7B-Instruct-4bit'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"

  mkdir -p "$cache_dir"
  : >"${cache_dir}/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove --backend mlx "$model_name" --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx remove clears cache' "remove failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "$cache_dir" ]]; then
    fail 'mlx remove clears cache' 'expected model cache dir to be removed'
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Removed MLX model: $model_name"; then
    fail 'mlx remove clears cache' "expected success message, got: $(cat "$stdout_file")"
    return
  fi

  pass 'mlx remove clears cache'
}

test_mlx_remove_quant_warns_and_ignores() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='mlx-community/Qwen2.5-7B-Instruct-4bit'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"
  mkdir -p "$cache_dir"
  : >"${cache_dir}/weights.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove --backend mlx "${model_name}:Q4_K_M" --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx remove ignores quant suffix with warning' "remove failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'does not use quant specifiers'; then
    fail 'mlx remove ignores quant suffix with warning' "expected quant warning, got: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "$cache_dir" ]]; then
    fail 'mlx remove ignores quant suffix with warning' 'expected model cache dir to be removed'
    return
  fi

  pass 'mlx remove ignores quant suffix with warning'
}

test_mlx_remove_fails_when_model_in_use_by_server() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='mlx-community/Qwen2.5-7B-Instruct-4bit'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"

  mkdir -p "$cache_dir"
  : >"${cache_dir}/weights.safetensors"

  cat >"${TEST_DIR}/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"comm=,args="* ]]; then
  cat <<'OUT'
mlx_lm.server /opt/homebrew/bin/mlx_lm.server --model mlx-community/Qwen2.5-7B-Instruct-4bit --port 8082
OUT
  exit 0
fi
echo "mock ps: unsupported args: $*" >&2
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/ps"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove --backend mlx "$model_name" --force
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'mlx remove blocks model in use by server' 'expected remove to fail while model is in use'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'currently in use by mlx_lm.chat or mlx_lm.server'; then
    fail 'mlx remove blocks model in use by server' "expected in-use error, got: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -d "$cache_dir" ]]; then
    fail 'mlx remove blocks model in use by server' 'expected model cache dir to remain'
    return
  fi

  pass 'mlx remove blocks model in use by server'
}

test_mlx_remove_fails_when_model_in_use_by_chat() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='mlx-community/Qwen2.5-7B-Instruct-4bit'
  local cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--Qwen2.5-7B-Instruct-4bit"

  mkdir -p "$cache_dir"
  : >"${cache_dir}/weights.safetensors"

  cat >"${TEST_DIR}/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"comm=,args="* ]]; then
  cat <<'OUT'
Python /opt/homebrew/bin/python /opt/homebrew/bin/mlx_lm.chat --model mlx-community/Qwen2.5-7B-Instruct-4bit
OUT
  exit 0
fi
echo "mock ps: unsupported args: $*" >&2
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/ps"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove --backend mlx "$model_name" --force
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'mlx remove blocks model in use by chat' 'expected remove to fail while model is in use'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'currently in use by mlx_lm.chat or mlx_lm.server'; then
    fail 'mlx remove blocks model in use by chat' "expected in-use error, got: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -d "$cache_dir" ]]; then
    fail 'mlx remove blocks model in use by chat' 'expected model cache dir to remain'
    return
  fi

  pass 'mlx remove blocks model in use by chat'
}

test_mlx_update_uses_uv_upgrade() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local uv_log="${TEST_DIR}/uv.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  cat >"${TEST_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CORRAL_UV_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/uv"
  export CORRAL_UV_LOG="$uv_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" update --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx update uses uv tool upgrade' "update failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$uv_log")" 'tool upgrade mlx-lm'; then
    fail 'mlx update uses uv tool upgrade' "expected uv upgrade call, got: $(cat "$uv_log")"
    return
  fi

  pass 'mlx update uses uv tool upgrade'
}

test_mlx_versions_reports_installed_version() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo '0.30.1'
EOF
  chmod +x "${TEST_DIR}/bin/python3"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" versions --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx versions reports installed package version' "versions failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'mlx' || ! assert_contains "$out" '0.30.1'; then
    fail 'mlx versions reports installed package version' "expected mlx version output, got: $out"
    return
  fi

  pass 'mlx versions reports installed package version'
}

test_mlx_versions_fallbacks_to_uv_tool_list() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  # Simulate a layout where python cannot import mlx_lm directly.
  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/python3"

  cat >"${TEST_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "tool" && "$2" == "list" ]]; then
  printf '%s\n' 'mlx-lm 0.31.2'
  exit 0
fi
exit 1
EOF
  chmod +x "${TEST_DIR}/bin/uv"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" versions --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx versions falls back to uv tool list' "versions failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'mlx' || ! assert_contains "$out" '0.31.2'; then
    fail 'mlx versions falls back to uv tool list' "expected uv-derived mlx version output, got: $out"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx status falls back to uv tool list' "status failed: $(cat "$stderr_file")"
    return
  fi

  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'installed (0.31.2)'; then
    fail 'mlx status falls back to uv tool list' "expected uv-derived status version output, got: $out"
    return
  fi

  pass 'mlx versions falls back to uv tool list'
  pass 'mlx status falls back to uv tool list'
}

test_mlx_prune_is_noop() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" prune --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx prune is a no-op' "prune failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" "Nothing to prune for MLX"; then
    fail 'mlx prune is a no-op' "expected no-op message, got: $out"
    return
  fi

  pass 'mlx prune is a no-op'
}

test_list_llama_cpp_ignores_non_gguf_models() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--unsloth--Qwen3.5-35B-A3B-GGUF" "model-Q4_K_M.gguf" 1024

  local mlx_cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--gemma-4-26b-a4b-it-4bit"
  mkdir -p "$mlx_cache_dir"
  : >"${mlx_cache_dir}/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --backend llama.cpp --quiet --models
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'llama.cpp list ignores non-gguf models' "list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_M'; then
    fail 'llama.cpp list ignores non-gguf models' "expected GGUF model in output, got: $out"
    return
  fi
  if assert_contains "$out" 'mlx-community/gemma-4-26b-a4b-it-4bit'; then
    fail 'llama.cpp list ignores non-gguf models' "did not expect non-GGUF mlx model in llama.cpp output, got: $out"
    return
  fi

  pass 'llama.cpp list ignores non-gguf models'
}

test_mlx_list_discovers_cache() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local model_name='mlx-community/gemma-4-26b-a4b-it-4bit'

  local mlx_cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--gemma-4-26b-a4b-it-4bit"
  mkdir -p "$mlx_cache_dir"
  : >"${mlx_cache_dir}/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --backend mlx --quiet --models
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx list discovers cache' "list failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "$model_name"; then
    fail 'mlx list discovers cache' "expected cache-discovered mlx model, got: $(cat "$stdout_file")"
    return
  fi

  pass 'mlx list discovers cache'
}

test_list_default_includes_both_backends() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--unsloth--Qwen3.5-35B-A3B-GGUF" "model-Q4_K_M.gguf" 1024

  local mlx_cache_dir="${HOME}/.cache/huggingface/hub/models--mlx-community--gemma-4-26b-a4b-it-4bit"
  mkdir -p "$mlx_cache_dir"
  : >"${mlx_cache_dir}/model.safetensors"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --quiet --models
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'default list includes both backends' "list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'unsloth/Qwen3.5-35B-A3B-GGUF:Q4_K_M'; then
    fail 'default list includes both backends' "expected llama.cpp GGUF entry, got: $out"
    return
  fi
  if ! assert_contains "$out" 'mlx-community/gemma-4-26b-a4b-it-4bit'; then
    fail 'default list includes both backends' "expected mlx cache entry, got: $out"
    return
  fi

  pass 'default list includes both backends'
}

test_mlx_uninstall_removes_tool() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local uv_log="${TEST_DIR}/uv.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  cat >"${TEST_DIR}/bin/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CORRAL_UV_LOG"
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/uv"
  export CORRAL_UV_LOG="$uv_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" uninstall --backend mlx --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'mlx uninstall removes tool' "uninstall failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$uv_log")" 'tool uninstall mlx-lm'; then
    fail 'mlx uninstall removes tool' "expected uv uninstall call, got: $(cat "$uv_log")"
    return
  fi

  pass 'mlx uninstall removes tool'
}

test_mlx_unsupported_platform_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Linux" "x86_64"
  cat >"${TEST_DIR}/bin/mlx_lm.chat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.chat"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend mlx demo/run-model
  if [[ $RUN_STATUS -ne 0 ]] && assert_contains "$(cat "$stderr_file")" 'MLX backend is only supported on macOS Apple Silicon'; then
    pass 'mlx backend errors on unsupported platform'
  else
    fail 'mlx backend errors on unsupported platform' "expected platform error, got: $(cat "$stderr_file")"
  fi
}

test_status_shows_backend_and_platform() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --backend mlx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'status shows backend and platform' "status failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'Platform  :'; then
    fail 'status shows backend and platform' "expected platform line, got: $out"
    return
  fi
  if ! assert_contains "$out" 'Backend   : mlx'; then
    fail 'status shows backend and platform' "expected mlx backend line, got: $out"
    return
  fi
  if ! assert_contains "$out" 'mlx-lm    : installed'; then
    fail 'status shows backend and platform' "expected mlx-lm installed line, got: $out"
    return
  fi

  pass 'status shows backend and platform'
}

test_status_combined_shows_both_backends() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  mkdir -p "${install_root}/llama-b1001"
  ln -sfn "${install_root}/llama-b1001" "${install_root}/current"

  cat >"${TEST_DIR}/bin/mlx_lm.generate" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${TEST_DIR}/bin/mlx_lm.generate"

  # Mock python3 for _mlx_lm_version.
  cat >"${TEST_DIR}/bin/python3" <<'EOF'
#!/usr/bin/env bash
echo "0.99.0"
EOF
  chmod +x "${TEST_DIR}/bin/python3"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" status --path "$install_root"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'status combined shows both backends' "status failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'llama.cpp : b1001'; then
    fail 'status combined shows both backends' "expected llama.cpp line, got: $out"
    return
  fi
  if ! assert_contains "$out" 'mlx-lm    : installed'; then
    fail 'status combined shows both backends' "expected mlx-lm line, got: $out"
    return
  fi

  pass 'status combined shows both backends'
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
  mkdir -p "$(dirname "${snapshot_dir}/${gguf_filename}")"
  ln -sf "${blob_dir}/${blob_hash}" "${snapshot_dir}/${gguf_filename}"
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

  if ! assert_contains "$out" 'MODEL' || ! assert_contains "$out" 'SIZE'; then
    fail 'list shows quant variants' "expected tabular headings in list output, got: $out"
    return
  fi

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
  if ! assert_contains "$out" 'demo/test-GGUF:Q4_K_M'; then
    fail 'list --quiet shows model:quant' "expected 'demo/test-GGUF:Q4_K_M', got '$out'"
    return
  fi

  pass 'list --quiet shows model:quant'
}

test_list_includes_profiles_and_models_sections() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  create_gguf_fixture "models--demo--combo-GGUF" "combo-Q4_K_M.gguf" 1024
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder 'demo/combo-GGUF:Q4_K_M'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list includes model/profile sections' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list includes model/profile sections' "list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'MODEL' || ! assert_contains "$out" 'PROFILE'; then
    fail 'list includes model/profile sections' "expected MODEL and PROFILE sections, got: $out"
    return
  fi
  if ! assert_contains "$out" 'demo/combo-GGUF:Q4_K_M'; then
    fail 'list includes model/profile sections' "expected model row, got: $out"
    return
  fi
  if ! assert_contains "$out" 'coder'; then
    fail 'list includes model/profile sections' "expected profile row, got: $out"
    return
  fi

  pass 'list includes model/profile sections'
}

test_list_models_profiles_scopes() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  create_gguf_fixture "models--demo--scope-GGUF" "scope-Q8_0.gguf" 1024
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set scoped 'demo/scope-GGUF:Q8_0'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list scope flags filter sections' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --models
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list scope flags filter sections' "list --models failed: $(cat "$stderr_file")"
    return
  fi
  local out_models
  out_models="$(cat "$stdout_file")"
  if ! assert_contains "$out_models" 'MODEL' || assert_contains "$out_models" 'PROFILE'; then
    fail 'list scope flags filter sections' "expected only model section for --models, got: $out_models"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --profiles
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list scope flags filter sections' "list --profiles failed: $(cat "$stderr_file")"
    return
  fi
  local out_profiles
  out_profiles="$(cat "$stdout_file")"
  if ! assert_contains "$out_profiles" 'PROFILE' || ! assert_contains "$out_profiles" 'scoped'; then
    fail 'list scope flags filter sections' "expected only profile section for --profiles, got: $out_profiles"
    return
  fi
  if assert_contains "$out_profiles" 'SIZE'; then
    fail 'list scope flags filter sections' "did not expect model table headers in --profiles output, got: $out_profiles"
    return
  fi

  pass 'list scope flags filter sections'
}

test_list_json_and_quiet_include_profiles() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  create_gguf_fixture "models--demo--jsonq-GGUF" "jsonq-UD-Q6_K.gguf" 1024
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set jcoder 'demo/jsonq-GGUF:UD-Q6_K'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include profiles and sections' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include profiles and sections' "list --json failed: $(cat "$stderr_file")"
    return
  fi

  local model_count profile_count
  model_count="$(jq '[ .[] | select(.kind == "MODEL") ] | length' "$stdout_file")"
  profile_count="$(jq '[ .[] | select(.kind == "PROFILE") ] | length' "$stdout_file")"
  if [[ "$model_count" -lt 1 || "$profile_count" -lt 1 ]]; then
    fail 'list json/quiet include profiles and sections' "expected MODEL and PROFILE records in json, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include profiles and sections' "list --quiet failed: $(cat "$stderr_file")"
    return
  fi

  local quiet_out
  quiet_out="$(cat "$stdout_file")"
  if ! assert_contains "$quiet_out" 'demo/jsonq-GGUF:UD-Q6_K'; then
    fail 'list json/quiet include profiles and sections' "expected model spec in quiet output, got: $quiet_out"
    return
  fi
  if ! assert_contains "$quiet_out" 'jcoder'; then
    fail 'list json/quiet include profiles and sections' "expected profile name in quiet output, got: $quiet_out"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --json --profiles
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include profiles and sections' "list --json --profiles failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_eq "$(jq '[ .[] | select(.kind != "PROFILE") ] | length' "$stdout_file")" '0'; then
    fail 'list json/quiet include profiles and sections' "expected only PROFILE records when scoped, got: $(cat "$stdout_file")"
    return
  fi

  pass 'list json/quiet include profiles and sections'
}

test_list_includes_templates_section() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set mytmp user/tmpl-model:Q4_K -- --temp 0.5
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list includes templates section' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list includes templates section' "list failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'TEMPLATE' || ! assert_contains "$out" 'TYPE'; then
    fail 'list includes templates section' "expected template section headers, got: $out"
    return
  fi
  if ! assert_contains "$out" 'mytmp'; then
    fail 'list includes templates section' "expected user template row, got: $out"
    return
  fi
  if ! assert_contains "$out" 'chat' || ! assert_contains "$out" 'code'; then
    fail 'list includes templates section' "expected built-in templates in list output, got: $out"
    return
  fi

  pass 'list includes templates section'
}

test_list_templates_scope() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set onlytmp user/tmpl-model:Q4_K -- --temp 0.5
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list --templates scopes output' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --templates
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list --templates scopes output' "list --templates failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'TEMPLATE' || assert_contains "$out" 'PROFILE'; then
    fail 'list --templates scopes output' "expected only template table section, got: $out"
    return
  fi
  if assert_contains "$out" 'SIZE'; then
    fail 'list --templates scopes output' "did not expect model table headers in --templates output, got: $out"
    return
  fi

  pass 'list --templates scopes output'
}

test_list_json_and_quiet_include_templates() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set jsonqtmp user/tmpl-model:Q4_K -- --temp 0.5
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include templates' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include templates' "list --json failed: $(cat "$stderr_file")"
    return
  fi

  local template_count
  template_count="$(jq '[ .[] | select(.kind == "TEMPLATE") ] | length' "$stdout_file")"
  if [[ "$template_count" -lt 1 ]]; then
    fail 'list json/quiet include templates' "expected TEMPLATE records in json, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --quiet --templates
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list json/quiet include templates' "list --quiet --templates failed: $(cat "$stderr_file")"
    return
  fi

  local quiet_out
  quiet_out="$(cat "$stdout_file")"
  if ! assert_contains "$quiet_out" 'jsonqtmp'; then
    fail 'list json/quiet include templates' "expected user template name in quiet output, got: $quiet_out"
    return
  fi
  if ! assert_contains "$quiet_out" 'chat' || ! assert_contains "$quiet_out" 'code'; then
    fail 'list json/quiet include templates' "expected built-in template names in quiet output, got: $quiet_out"
    return
  fi

  pass 'list json/quiet include templates'
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

test_list_detects_nested_snapshot_quant() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--nested-GGUF" "BF16/nested-BF16.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" list --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'list detects quants in nested snapshot paths' "list --quiet failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" 'demo/nested-GGUF:BF16'; then
    fail 'list detects quants in nested snapshot paths' "expected nested BF16 quant row, got: $(cat "$stdout_file")"
    return
  fi

  pass 'list detects quants in nested snapshot paths'
}

test_remove_quant_is_case_insensitive() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  create_gguf_fixture "models--demo--case-GGUF" "case-Q4_K_M.gguf" 1024

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove 'demo/case-GGUF:q4-k-m' --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove quant matching is case-insensitive' "remove failed: $(cat "$stderr_file")"
    return
  fi

  local hf_hub_dir="${HOME}/.cache/huggingface/hub"
  if [[ -d "${hf_hub_dir}/models--demo--case-GGUF" ]]; then
    fail 'remove quant matching is case-insensitive' 'expected model dir to be removed after deleting only quant'
    return
  fi

  pass 'remove quant matching is case-insensitive'
}

test_pull_quant_match_is_case_insensitive() {
  local install_root="${HOME}/install-root"
  local current_link="${install_root}/current"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local args_log="${TEST_DIR}/llama-cli-args.log"
  local model_spec='demo/case-GGUF:q4-k-m'

  mkdir -p "$current_link"
  : >"$args_log"

  create_gguf_fixture "models--demo--case-GGUF" "case-Q4_K_M.gguf" 1024

  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$CORRAL_LLAMA_CLI_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  export CORRAL_INSTALL_ROOT="$install_root"
  export CORRAL_LLAMA_CLI_ARGS_LOG="$args_log"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" pull "$model_spec"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'pull quant matching is case-insensitive' "pull failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stdout_file")" "Model already cached: ${model_spec}"; then
    fail 'pull quant matching is case-insensitive' "expected already-cached message for equivalent quant, got: $(cat "$stdout_file")"
    return
  fi

  if [[ -s "$args_log" ]]; then
    fail 'pull quant matching is case-insensitive' 'expected pull to skip llama-cli when equivalent quant is cached'
    return
  fi

  pass 'pull quant matching is case-insensitive'
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
  },
  {
    "modelId": "demo/gemma-raw-GGUF",
    "downloads": 456,
    "likes": 7,
    "siblings": [
      {"rfilename": "gemma-raw.gguf"}
    ]
  },
  {
    "modelId": "demo/not-gguf-transformers",
    "downloads": 999999,
    "likes": 999,
    "library_name": "transformers",
    "tags": ["transformers", "safetensors"],
    "siblings": [
      {"rfilename": "model.safetensors"},
      {"rfilename": "README.md"}
    ]
  }
]
EOF
}

write_hf_search_fixture_mlx() {
  local fixtures_dir="$1"
  cat >"${fixtures_dir}/hf-search-results.json" <<'EOF'
[
  {
    "modelId": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "downloads": 5000,
    "likes": 200,
    "tags": ["mlx", "text-generation"],
    "siblings": []
  },
  {
    "modelId": "org/mlx-tagged-model",
    "downloads": 1200,
    "likes": 80,
    "tags": ["MLX", "other"],
    "siblings": []
  },
  {
    "modelId": "org/gguf-only-model",
    "downloads": 7000,
    "likes": 300,
    "library_name": "gguf",
    "tags": ["gguf"],
    "siblings": [{"rfilename": "model-Q4_K_M.gguf"}]
  },
  {
    "modelId": "org/transformers-model",
    "downloads": 9999,
    "likes": 400,
    "library_name": "transformers",
    "tags": ["transformers"],
    "siblings": [{"rfilename": "model.safetensors"}]
  }
]
EOF
}

test_search_mlx_backend_filters_results() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture_mlx "$CORRAL_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search --backend mlx qwen --quiet
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --backend mlx filters to mlx-compatible models' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'mlx-community/Qwen2.5-7B-Instruct-4bit'; then
    fail 'search --backend mlx filters to mlx-compatible models' "expected mlx-community model, got: $out"
    return
  fi

  if ! assert_contains "$out" 'org/mlx-tagged-model'; then
    fail 'search --backend mlx filters to mlx-compatible models' "expected mlx-tagged model, got: $out"
    return
  fi

  if assert_contains "$out" 'org/gguf-only-model' || assert_contains "$out" 'org/transformers-model'; then
    fail 'search --backend mlx filters to mlx-compatible models' "unexpected non-mlx models in output: $out"
    return
  fi

  pass 'search --backend mlx filters to mlx-compatible models'
}

test_search_mlx_quants_warns_and_ignores() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture_mlx "$CORRAL_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search --backend mlx qwen --quants --json
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --backend mlx ignores --quants with warning' "search failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" '--quants is only supported for llama.cpp/GGUF search'; then
    fail 'search --backend mlx ignores --quants with warning' "expected warning, got: $(cat "$stderr_file")"
    return
  fi

  if [[ "$(jq '[ .[] | select(has("quants")) ] | length' "$stdout_file")" -ne 0 ]]; then
    fail 'search --backend mlx ignores --quants with warning' "did not expect quants fields in mlx json output: $(cat "$stdout_file")"
    return
  fi

  pass 'search --backend mlx ignores --quants with warning'
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

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  if ! assert_contains "$out" 'demo/gemma-raw-GGUF'; then
    fail 'search returns tabular results' "expected 'demo/gemma-raw-GGUF' in output, got: $out"
    return
  fi

  if assert_contains "$out" 'demo/not-gguf-transformers'; then
    fail 'search returns tabular results' "expected non-GGUF model to be excluded, got: $out"
    return
  fi

  pass 'search returns tabular results'
}

test_search_quiet() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  if ! assert_contains "$out" 'demo/gemma-raw-GGUF'; then
    fail 'search --quiet prints only names' "expected model without parseable quant in quiet output, got: $out"
    return
  fi

  if assert_contains "$out" 'MODEL'; then
    fail 'search --quiet prints only names' "unexpected column header in quiet output"
    return
  fi

  if assert_contains "$out" 'demo/not-gguf-transformers'; then
    fail 'search --quiet prints only names' "expected non-GGUF model to be excluded, got: $out"
    return
  fi

  pass 'search --quiet prints only names'
}

test_search_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  if [[ "$(jq 'length' "$stdout_file")" -ne 3 ]]; then
    fail 'search --json output' "expected 3 GGUF results in fixture output, got: $(cat "$stdout_file")"
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
  val="$(tr -d '[:space:]' < "$stdout_file")"
  if [[ "$val" != '[]' ]]; then
    fail 'search empty results --json' "expected '[]', got: $val"
    return
  fi

  pass 'search empty results --json'
}

test_search_sort_option() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

  # Default sort should be trendingScore.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma
  if ! assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/curl.log")" 'sort=trendingScore'; then
    fail 'search default sort is trending' "expected sort=trendingScore in request URL"
    return
  fi
  pass 'search default sort is trending'

  # --sort downloads should pass sort=downloads to the API.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --sort downloads
  if ! assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/curl.log")" 'sort=downloads'; then
    fail 'search --sort downloads' "expected sort=downloads in request URL"
    return
  fi
  pass 'search --sort downloads'

  # --sort newest should map to lastModified in the URL.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --sort newest
  if ! assert_contains "$(cat "${CORRAL_TEST_LOG_DIR}/curl.log")" 'sort=lastModified'; then
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

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma --quants
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'search --quants tabular output' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'QUANTS'; then
    fail 'search --quants tabular output' "expected QUANTS column header, got: $out"
    return
  fi

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

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  if ! assert_contains "$out" 'demo/gemma-raw-GGUF'; then
    fail 'search --quants --quiet prints MODEL:QUANT lines' "expected model without parseable quant to still be listed, got: $out"
    return
  fi

  pass 'search --quants --quiet prints MODEL:QUANT lines'
}

test_search_quants_json() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  write_hf_search_fixture "$CORRAL_TEST_FIXTURES_DIR"

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

  local open_log="${CORRAL_TEST_LOG_DIR}/open.log"
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

test_ps_ignores_awk_false_positive() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_ps "${TEST_DIR}/bin/ps"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" ps
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'ps excludes awk false positive' "ps failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'llama-server'; then
    fail 'ps excludes awk false positive' "expected llama-server row, got: $out"
    return
  fi

  if ! assert_contains "$out" 'llama-cli'; then
    fail 'ps excludes awk false positive' "expected llama-cli row, got: $out"
    return
  fi

  if ! assert_contains "$out" 'mlx_lm.server'; then
    fail 'ps includes mlx server rows' "expected mlx_lm.server row, got: $out"
    return
  fi

  if ! assert_contains "$out" 'mlx_lm.chat'; then
    fail 'ps includes mlx chat rows' "expected mlx_lm.chat row, got: $out"
    return
  fi

  if assert_contains "$out" 'awk'; then
    fail 'ps excludes awk false positive' "did not expect awk row, got: $out"
    return
  fi

  pass 'ps excludes awk false positive'
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

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

  local profile_file="${CORRAL_PROFILES_DIR}/coder"
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

test_profile_removed_subcommands_error() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile list
  if [[ $RUN_STATUS -eq 0 ]] || ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'removed profile subcommands error' "expected profile list to be rejected, got: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile remove coder
  if [[ $RUN_STATUS -eq 0 ]] || ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'removed profile subcommands error' "expected profile remove to be rejected, got: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile templates
  if [[ $RUN_STATUS -eq 0 ]] || ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'removed profile subcommands error' "expected profile templates to be rejected, got: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile new coder code user/model
  if [[ $RUN_STATUS -eq 0 ]] || ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'removed profile subcommands error' "expected profile new to be rejected, got: $(cat "$stderr_file")"
    return
  fi

  pass 'removed profile subcommands error'
}

test_remove_profile_via_top_level_remove() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder 'demo/model:Q4_K'
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove/rm supports profile removal' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" remove coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove/rm supports profile removal' "remove profile failed: $(cat "$stderr_file")"
    return
  fi
  if [[ -f "${CORRAL_PROFILES_DIR}/coder" ]]; then
    fail 'remove/rm supports profile removal' 'expected profile file removed by top-level remove'
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder 'demo/model:Q4_K'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" rm coder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'remove/rm supports profile removal' "rm profile failed: $(cat "$stderr_file")"
    return
  fi
  if [[ -f "${CORRAL_PROFILES_DIR}/coder" ]]; then
    fail 'remove/rm supports profile removal' 'expected profile file removed by top-level rm alias'
    return
  fi

  pass 'remove/rm supports profile removal'
}

test_profile_remove_missing_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile remove nonexistent
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile remove subcommand removed' 'expected non-zero exit'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'profile remove subcommand removed' "expected unknown subcommand error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile remove subcommand removed'
}

test_profile_duplicate() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 65536 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile duplicate coder coder-hi-ctx
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile duplicate copies profile' "profile duplicate failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${CORRAL_PROFILES_DIR}/coder-hi-ctx" ]]; then
    fail 'profile duplicate copies profile' "expected destination profile file to exist"
    return
  fi

  if ! diff -q "${CORRAL_PROFILES_DIR}/coder" "${CORRAL_PROFILES_DIR}/coder-hi-ctx" >/dev/null 2>&1; then
    fail 'profile duplicate copies profile' "expected source and destination to have identical contents"
    return
  fi

  pass 'profile duplicate copies profile'
}

test_profile_duplicate_dest_exists_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 32768
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- --ctx-size 65536

  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set overwrites existing' "second set failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_contains "$(cat "${CORRAL_PROFILES_DIR}/coder")" '--ctx-size'; then
    fail 'profile set overwrites existing' "expected flags in overwritten profile"
    return
  fi

  # The old value 32768 should not appear; 65536 should.
  if assert_contains "$(cat "${CORRAL_PROFILES_DIR}/coder")" '32768'; then
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"
  export CORRAL_RUN_ARGS_LOG="$run_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 --temp 0.2 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend llama.cpp coder
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"
  export CORRAL_SERVE_ARGS_LOG="$serve_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 --temp 0.2 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve --backend llama.cpp coder
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_INSTALL_ROOT="$install_root"

  mkdir -p "$current_link"
  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"
  export CORRAL_SERVE_ARGS_LOG="$serve_args_log"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set coder \
    'unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL' -- \
    --ctx-size 65536 -ngl 99

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve --backend llama.cpp coder -- --port 8081
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles-empty"
  export CORRAL_INSTALL_ROOT="$install_root"
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

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_INSTALL_ROOT="$install_root"
  unset HF_TOKEN HF_HUB_TOKEN HUGGING_FACE_HUB_TOKEN

  mkdir -p "$current_link"
  cat >"${current_link}/llama-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_RUN_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-cli"

  cat >"${current_link}/llama-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CORRAL_SERVE_ARGS_LOG"
exit 0
EOF
  chmod +x "${current_link}/llama-server"

  export CORRAL_RUN_ARGS_LOG="$run_args_log"
  export CORRAL_SERVE_ARGS_LOG="$serve_args_log"

  # Write a profile with common flags and per-command sections.
  mkdir -p "$CORRAL_PROFILES_DIR"
  cat >"${CORRAL_PROFILES_DIR}/coder" <<'PROFILE'
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
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" serve --backend llama.cpp coder
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
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" run --backend llama.cpp coder
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

test_profile_set_builtin_with_model() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  unset CORRAL_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set mycoder code user/qwen2.5:Q4_K
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set from builtin with model' "command failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "saved"; then
    fail 'profile set from builtin with model' "expected success message, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show mycoder
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set from builtin with model' "show failed: $(cat "$stderr_file")"
    return
  fi

  local content
  content="$(cat "$stdout_file")"
  if ! assert_contains "$content" "model=user/qwen2.5:Q4_K"; then
    fail 'profile set from builtin with model' "expected model line, got: $content"
    return
  fi
  if ! assert_contains "$content" "--temp 0.2"; then
    fail 'profile set from builtin with model' "expected code template flag --temp, got: $content"
    return
  fi
  if ! assert_contains "$content" "-ngl 999"; then
    fail 'profile set from builtin with model' "expected code template flag -ngl, got: $content"
    return
  fi

  pass 'profile set from builtin with model'
}

test_profile_set_builtin_no_model_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  unset CORRAL_TEMPLATES_DIR

  # 'code' built-in has no model= line; no model arg provided → should error.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set mycoder code
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile set builtin no model errors' "expected failure when no model provided"
    return
  fi
  if ! assert_contains "$(cat "$stderr_file")" "no model specified"; then
    fail 'profile set builtin no model errors' "expected 'no model specified' error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile set builtin no model errors'
}

test_profile_set_user_template() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  # Create a user-defined template with a default model.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set mytemplate user/mymodel:Q4_K -- --temp 0.5 --ctx-size 4096
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set from user template' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  # Create a profile from it (no model arg — should use template's default).
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set myprofile mytemplate
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set from user template' "profile set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show myprofile
  local content
  content="$(cat "$stdout_file")"
  if ! assert_contains "$content" "model=user/mymodel:Q4_K"; then
    fail 'profile set from user template' "expected default model from template, got: $content"
    return
  fi
  if ! assert_contains "$content" "--temp 0.5"; then
    fail 'profile set from user template' "expected template flag --temp, got: $content"
    return
  fi

  pass 'profile set from user template'
}

test_profile_set_template_overwrites_existing() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_PROFILES_DIR="${HOME}/.config/corral/profiles"
  unset CORRAL_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set mypro user/original:Q4_K -- --temp 0.9
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set template overwrites existing' "initial set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile set mypro code user/updated:Q6_K
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set template overwrites existing' "overwrite set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile show mypro
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'profile set template overwrites existing' "profile show failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'model=user/updated:Q6_K'; then
    fail 'profile set template overwrites existing' "expected updated model in profile, got: $out"
    return
  fi
  if ! assert_contains "$out" '--temp 0.2'; then
    fail 'profile set template overwrites existing' "expected template flags in profile, got: $out"
    return
  fi
  if assert_contains "$out" '--temp 0.9'; then
    fail 'profile set template overwrites existing' "expected old profile content to be replaced, got: $out"
    return
  fi

  pass 'profile set template overwrites existing'
}

test_profile_templates_subcommand_removed() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" profile templates
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'profile templates subcommand removed' 'expected non-zero exit'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'Unknown profile subcommand'; then
    fail 'profile templates subcommand removed' "expected unknown subcommand error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'profile templates subcommand removed'
}

test_template_show_builtin() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  unset CORRAL_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template show code
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template show builtin' "command failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" "--temp 0.2"; then
    fail 'template show builtin' "expected '--temp 0.2' in code template, got: $out"
    return
  fi
  if ! assert_contains "$out" "-ngl 999"; then
    fail 'template show builtin' "expected '-ngl 999' in code template, got: $out"
    return
  fi

  pass 'template show builtin'
}

test_template_set_and_show() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set mywork user/work-model -- --temp 0.3 --ctx-size 8192
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template set and show' "template-set failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "saved"; then
    fail 'template set and show' "expected 'saved' message, got: $(cat "$stdout_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template show mywork
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template set and show' "template-show failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" "model=user/work-model"; then
    fail 'template set and show' "expected model line, got: $out"
    return
  fi
  if ! assert_contains "$out" "--temp 0.3"; then
    fail 'template set and show' "expected --temp 0.3, got: $out"
    return
  fi

  pass 'template set and show'
}

test_template_remove() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template set mytmp -- --temp 0.5
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template remove' "template-set failed: $(cat "$stderr_file")"
    return
  fi

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template remove mytmp
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'template remove' "template-remove failed: $(cat "$stderr_file")"
    return
  fi
  if ! assert_contains "$(cat "$stdout_file")" "removed"; then
    fail 'template remove' "expected 'removed' message, got: $(cat "$stdout_file")"
    return
  fi

  # Subsequent show should fail.
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template show mytmp
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'template remove' "expected show to fail after removal"
    return
  fi

  pass 'template remove'
}

test_template_remove_builtin_errors() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  unset CORRAL_TEMPLATES_DIR

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template remove chat
  if [[ $RUN_STATUS -eq 0 ]]; then
    fail 'template remove builtin errors' "expected failure when removing built-in template"
    return
  fi
  if ! assert_contains "$(cat "$stderr_file")" "built-in"; then
    fail 'template remove builtin errors' "expected 'built-in' in error, got: $(cat "$stderr_file")"
    return
  fi

  pass 'template remove builtin errors'
}

test_template_user_overrides_builtin() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  export CORRAL_TEMPLATES_DIR="${HOME}/.config/corral/templates"

  # Write a user template named 'code' that overrides the built-in.
  mkdir -p "$CORRAL_TEMPLATES_DIR"
  cat >"${CORRAL_TEMPLATES_DIR}/code" <<'EOF'
--temp 0.9
--ctx-size 1024
EOF

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" template show code
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

# ── combined backend tests ────────────────────────────────────────────────────

write_hf_search_fixture_combined() {
  local fixtures_dir="$1"
  cat >"${fixtures_dir}/hf-search-results.json" <<'EOF'
[
  {
    "modelId": "demo/gemma-GGUF",
    "downloads": 12345,
    "likes": 42,
    "library_name": "gguf",
    "tags": ["gguf"],
    "siblings": [
      {"rfilename": "gemma-Q4_K_M.gguf"},
      {"rfilename": "gemma-Q8_0.gguf"}
    ]
  },
  {
    "modelId": "mlx-community/gemma-4bit",
    "downloads": 5000,
    "likes": 200,
    "tags": ["mlx", "text-generation"],
    "siblings": []
  },
  {
    "modelId": "demo/gemma-both",
    "downloads": 3000,
    "likes": 90,
    "tags": ["mlx", "gguf"],
    "siblings": [
      {"rfilename": "gemma-both-Q4_K_M.gguf"}
    ]
  },
  {
    "modelId": "org/transformers-only",
    "downloads": 9999,
    "likes": 400,
    "library_name": "transformers",
    "tags": ["transformers"],
    "siblings": [{"rfilename": "model.safetensors"}]
  }
]
EOF
}

test_combined_install_flow() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  # Mock arm64 so the combined path is taken.
  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  # Create fixtures for macos-arm64 (forced by the mocked uname).
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined install installs llama.cpp' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${install_root}/llama-b1000/.install-complete" ]]; then
    fail 'combined install installs llama.cpp' 'expected llama.cpp install marker to exist'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'uv not found'; then
    fail 'combined install skips mlx gracefully when uv absent' \
      "expected 'uv not found' notice for mlx skip, got stderr: $(cat "$stderr_file")"
    return
  fi

  pass 'combined install installs llama.cpp'
  pass 'combined install skips mlx gracefully when uv absent'
}

test_combined_install_uses_homebrew_for_uv() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"
  local brew_log="${TEST_DIR}/brew.log"
  local uv_log="${TEST_DIR}/uv.log"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"
  write_mock_brew "${TEST_DIR}/bin/brew"

  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'

  export CORRAL_BREW_LOG="$brew_log"
  export CORRAL_UV_LOG="$uv_log"
  export CORRAL_TEST_UV_PATH="${TEST_DIR}/bin/uv"

  run_cmd_with_input 'y' "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined install uses Homebrew for uv bootstrap' "install failed: $(cat "$stderr_file")"
    return
  fi

  if [[ ! -f "${install_root}/llama-b1000/.install-complete" ]]; then
    fail 'combined install still installs llama.cpp while bootstrapping uv' 'expected llama.cpp install marker to exist'
    return
  fi

  if ! assert_contains "$(cat "$brew_log")" 'install uv'; then
    fail 'combined install uses Homebrew for uv bootstrap' "expected brew install uv call, got: $(cat "$brew_log")"
    return
  fi

  if ! assert_contains "$(cat "$uv_log")" 'tool install mlx-lm'; then
    fail 'combined install continues with mlx install after Homebrew uv' "expected uv tool install mlx-lm call, got: $(cat "$uv_log")"
    return
  fi

  pass 'combined install uses Homebrew for uv bootstrap'
  pass 'combined install still installs llama.cpp while bootstrapping uv'
  pass 'combined install continues with mlx install after Homebrew uv'
}

test_combined_update_flow() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  create_fixture_tarball "$CORRAL_TEST_FIXTURES_DIR" 'b1001' 'macos-arm64'
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1000' 'macos-arm64'
  write_release_json "$CORRAL_TEST_FIXTURES_DIR" 'b1001' 'macos-arm64'

  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1000'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" install --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined update flow' "initial install failed: $(cat "$stderr_file")"
    return
  fi

  write_latest_pointer "$CORRAL_TEST_STATE_DIR" 'b1001'
  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" update --path "$install_root" --no-shell-profile
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined update flow' "update failed: $(cat "$stderr_file")"
    return
  fi

  if ! assert_eq "$(basename "$(readlink "${install_root}/current")")" 'llama-b1001'; then
    fail 'combined update updates llama.cpp' 'expected current symlink to point at llama-b1001 after update'
    return
  fi

  if ! assert_contains "$(cat "$stderr_file")" 'skipping MLX update'; then
    fail 'combined update skips mlx gracefully when uv absent' \
      "expected 'skipping MLX update' notice, got stderr: $(cat "$stderr_file")"
    return
  fi

  pass 'combined update updates llama.cpp'
  pass 'combined update skips mlx gracefully when uv absent'
}

test_combined_uninstall_flow() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  mkdir -p "${install_root}/llama-b1000"
  ln -sfn "${install_root}/llama-b1000" "${install_root}/current"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" uninstall --path "$install_root" --force
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined uninstall removes llama.cpp' "uninstall failed: $(cat "$stderr_file")"
    return
  fi

  if [[ -d "$install_root" ]]; then
    fail 'combined uninstall removes llama.cpp' 'expected install root to be removed'
    return
  fi

  local out
  out="$(cat "$stdout_file")"
  if ! assert_contains "$out" 'mlx-lm is not installed'; then
    fail 'combined uninstall reports mlx not installed' \
      "expected mlx not-installed notice, got: $out"
    return
  fi

  pass 'combined uninstall removes llama.cpp'
  pass 'combined uninstall reports mlx not installed'
}

test_combined_versions_flow() {
  local install_root="${HOME}/install-root"
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  mkdir -p "${install_root}/llama-b1000" "${install_root}/llama-b1001"
  ln -sfn "${install_root}/llama-b1001" "${install_root}/current"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" versions --path "$install_root"
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined versions shows both sections' "versions failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'VERSION' || ! assert_contains "$out" 'STATUS'; then
    fail 'combined versions shows llama.cpp section' "expected VERSION/STATUS headers, got: $out"
    return
  fi

  if ! assert_contains "$out" 'b1001' || ! assert_contains "$out" 'current'; then
    fail 'combined versions shows llama.cpp section' "expected active version in output, got: $out"
    return
  fi

  if ! assert_contains "$out" 'mlx' || ! assert_contains "$out" 'not installed'; then
    fail 'combined versions shows mlx section' "expected mlx not-installed in output, got: $out"
    return
  fi

  pass 'combined versions shows llama.cpp section'
  pass 'combined versions shows mlx section'
}

test_combined_search_flow() {
  local stdout_file="${TEST_DIR}/stdout"
  local stderr_file="${TEST_DIR}/stderr"

  write_mock_uname "${TEST_DIR}/bin/uname" "Darwin" "arm64"

  write_hf_search_fixture_combined "$CORRAL_TEST_FIXTURES_DIR"

  run_cmd "$stdout_file" "$stderr_file" bash "$SCRIPT_PATH" search gemma
  if [[ $RUN_STATUS -ne 0 ]]; then
    fail 'combined search shows TYPE column' "search failed: $(cat "$stderr_file")"
    return
  fi

  local out
  out="$(cat "$stdout_file")"

  if ! assert_contains "$out" 'TYPE'; then
    fail 'combined search shows TYPE column' "expected TYPE column header, got: $out"
    return
  fi

  if ! assert_contains "$out" 'demo/gemma-GGUF'; then
    fail 'combined search includes llama.cpp models' "expected GGUF model in output, got: $out"
    return
  fi

  if ! assert_contains "$out" 'mlx-community/gemma-4bit'; then
    fail 'combined search includes mlx models' "expected MLX model in output, got: $out"
    return
  fi

  if assert_contains "$out" 'org/transformers-only'; then
    fail 'combined search excludes non-gguf non-mlx models' "did not expect transformers-only model, got: $out"
    return
  fi

  pass 'combined search shows TYPE column'
  pass 'combined search includes llama.cpp models'
  pass 'combined search includes mlx models'
  pass 'combined search excludes non-gguf non-mlx models'
}

main() {
  command -v jq >/dev/null 2>&1 || {
    echo 'jq is required to run smoke tests.' >&2
    exit 1
  }

  setup_test_env
  test_generated_standalone_script
  setup_test_env
  test_top_level_help
  test_argument_parsing_errors

  setup_test_env
  test_install_flow

  setup_test_env
  test_install_rewrites_stale_bash_path_block

  setup_test_env
  test_install_creates_bash_completion_loader_when_bashrc_missing

  setup_test_env
  test_install_creates_zsh_completion_loader

  setup_test_env
  test_install_zsh_completions_respect_zdotdir

  setup_test_env
  test_update_flow

  setup_test_env
  test_pull_noninteractive

  setup_test_env
  test_pull_quant_not_confused_by_other_cached_quant

  setup_test_env
  test_status_and_versions

  setup_test_env
  test_prune_and_uninstall

  setup_test_env
  test_remove_model_force

  setup_test_env
  test_run_and_serve_forwarding

  setup_test_env
  test_launch_requires_port_when_multiple_servers

  setup_test_env
  test_launch_pi_updates_configs_and_reuses_matching_config

  setup_test_env
  test_launch_pi_backs_up_matching_preexisting_config_once

  setup_test_env
  test_launch_opencode_updates_jsonc_and_launches_tool

  setup_test_env
  test_launch_codex_is_unsupported

  setup_test_env
  test_mlx_install_uv_flow

  setup_test_env
  test_mlx_run_dispatches

  setup_test_env
  test_mlx_serve_dispatches

  setup_test_env
  test_mlx_run_with_profile

  setup_test_env
  test_mlx_run_profile_backend_sections

  setup_test_env
  test_mlx_serve_with_profile

  setup_test_env
  test_llama_run_profile_backend_sections

  setup_test_env
  test_profile_set_from_template_preserves_backend_sections

  setup_test_env
  test_template_set_preserves_backend_sections

  setup_test_env
  test_template_backend_sections_inherited_by_profile

  setup_test_env
  test_mlx_quant_spec_warns

  setup_test_env
  test_mlx_pull_dispatches_generate

  setup_test_env
  test_mlx_pull_quant_spec_warns

  setup_test_env
  test_mlx_list_shows_cached_models

  setup_test_env
  test_mlx_remove_deletes_cache

  setup_test_env
  test_mlx_remove_quant_warns_and_ignores

  setup_test_env
  test_mlx_remove_fails_when_model_in_use_by_server

  setup_test_env
  test_mlx_remove_fails_when_model_in_use_by_chat

  setup_test_env
  test_mlx_update_uses_uv_upgrade

  setup_test_env
  test_mlx_versions_reports_installed_version

  setup_test_env
  test_mlx_versions_fallbacks_to_uv_tool_list

  setup_test_env
  test_mlx_prune_is_noop

  setup_test_env
  test_mlx_uninstall_removes_tool

  setup_test_env
  test_mlx_unsupported_platform_errors

  setup_test_env
  test_status_shows_backend_and_platform

  setup_test_env
  test_status_combined_shows_both_backends

  setup_test_env
  test_list_llama_cpp_ignores_non_gguf_models

  setup_test_env
  test_mlx_list_discovers_cache

  setup_test_env
  test_list_default_includes_both_backends

  setup_test_env
  test_list_shows_quant_variants

  setup_test_env
  test_list_json_includes_quant

  setup_test_env
  test_list_quiet_includes_quant

  setup_test_env
  test_list_includes_profiles_and_models_sections

  setup_test_env
  test_list_models_profiles_scopes

  setup_test_env
  test_list_json_and_quiet_include_profiles

  setup_test_env
  test_list_includes_templates_section

  setup_test_env
  test_list_templates_scope

  setup_test_env
  test_list_json_and_quiet_include_templates

  setup_test_env
  test_remove_specific_quant

  setup_test_env
  test_remove_last_quant_cleans_dir

  setup_test_env
  test_remove_missing_quant_errors

  setup_test_env
  test_list_detects_nested_snapshot_quant

  setup_test_env
  test_remove_quant_is_case_insensitive

  setup_test_env
  test_pull_quant_match_is_case_insensitive

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
  test_search_mlx_backend_filters_results

  setup_test_env
  test_search_mlx_quants_warns_and_ignores

  setup_test_env
  test_browse_opens_url

  setup_test_env
  test_browse_print_flag

  setup_test_env
  test_browse_strips_quant

  setup_test_env
  test_browse_no_model_errors

  setup_test_env
  test_ps_ignores_awk_false_positive

  setup_test_env
  test_search_bad_argument_errors

  setup_test_env
  test_profile_set_and_show

  setup_test_env
  test_profile_removed_subcommands_error

  setup_test_env
  test_remove_profile_via_top_level_remove

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
  test_profile_set_builtin_with_model

  setup_test_env
  test_profile_set_builtin_no_model_errors

  setup_test_env
  test_profile_set_user_template

  setup_test_env
  test_profile_set_template_overwrites_existing

  setup_test_env
  test_profile_templates_subcommand_removed

  setup_test_env
  test_template_show_builtin

  setup_test_env
  test_template_set_and_show

  setup_test_env
  test_template_remove

  setup_test_env
  test_template_remove_builtin_errors

  setup_test_env
  test_template_user_overrides_builtin

  setup_test_env
  test_combined_install_flow

  setup_test_env
  test_combined_install_uses_homebrew_for_uv

  setup_test_env
  test_combined_update_flow

  setup_test_env
  test_combined_uninstall_flow

  setup_test_env
  test_combined_versions_flow

  setup_test_env
  test_combined_search_flow

  printf '\n'
  printf 'Passed: %s\n' "$PASS_COUNT"

  if [[ $FAIL_COUNT -ne 0 ]]; then
    printf 'Failed: %s\n' "$FAIL_COUNT"
    exit 1
  fi

  printf 'Failed: 0\n'
}

main "$@"
