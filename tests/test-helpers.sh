#!/usr/bin/env bash
# Shared test harness for fold tests.
# Source this file from individual test scripts.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
# SCRIPT_PATH and RUN_STATUS are read by the scripts that source this file.
# shellcheck disable=SC2034
SCRIPT_PATH="${ROOT_DIR}/src/fold.sh"
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

assert_match() {
  local actual="$1"
  local pattern="$2"
  [[ "$actual" =~ $pattern ]]
}

run_cmd() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2

  set +e
  "$@" >"$stdout_file" 2>"$stderr_file"
  # shellcheck disable=SC2034  # RUN_STATUS is read by tests that source this file
  RUN_STATUS=$?
  set -e
}

# Source the fold modules into the current shell for unit testing.
# Sets up required global variables and sources all lib modules.
source_fold_libs() {
  SCRIPT_NAME="fold"
  DEFAULT_INSTALL_ROOT="${HOME}/.llama.cpp"
  DEFAULT_PROFILES_DIR="${HOME}/.config/fold/profiles"
  DEFAULT_TEMPLATES_DIR="${HOME}/.config/fold/templates"
  HF_HUB_DIR="${HOME}/.cache/huggingface/hub"
  SHELL_PROFILE_EDIT_DECISION=""
  # shellcheck disable=SC2034  # FOLD_VERSION is read by the sourced lib modules
  FOLD_VERSION="dev"

  source "${ROOT_DIR}/src/lib/fold-helpers.sh"
  source "${ROOT_DIR}/src/lib/fold-cache.sh"
  source "${ROOT_DIR}/src/lib/fold-profiles.sh"
  source "${ROOT_DIR}/src/lib/fold-runtime.sh"
  source "${ROOT_DIR}/src/lib/fold-search.sh"
  source "${ROOT_DIR}/src/lib/fold-completions.sh"
}

report_results() {
  echo
  printf 'Passed: %d\n' "$PASS_COUNT"
  printf 'Failed: %d\n' "$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -ne 0 ]]; then
    exit 1
  fi
}
