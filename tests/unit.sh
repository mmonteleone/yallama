#!/usr/bin/env bash
# Unit tests for pure helper functions (corral-cache.sh, corral-helpers.sh).
# These tests exercise functions directly without running corral as a subprocess.

# shellcheck source=tests/test-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Override HOME/HF_HUB_DIR for isolation.
HOME="$(mktemp -d "${TEST_ROOT}/home.XXXXXX")"
HF_HUB_DIR="${HOME}/.cache/huggingface/hub"

source_corral_libs

# ── _parse_model_spec ─────────────────────────────────────────────────────────

test_parse_model_spec_without_quant() {
  _parse_model_spec "user/model"
  if assert_eq "$REPLY_MODEL" "user/model" && assert_eq "$REPLY_QUANT" ""; then
    pass 'parse_model_spec without quant'
  else
    fail 'parse_model_spec without quant' "got model='$REPLY_MODEL' quant='$REPLY_QUANT'"
  fi
}

test_parse_model_spec_with_quant() {
  _parse_model_spec "user/model:Q4_K_M"
  if assert_eq "$REPLY_MODEL" "user/model" && assert_eq "$REPLY_QUANT" "Q4_K_M"; then
    pass 'parse_model_spec with quant'
  else
    fail 'parse_model_spec with quant' "got model='$REPLY_MODEL' quant='$REPLY_QUANT'"
  fi
}

test_parse_model_spec_with_compound_quant() {
  _parse_model_spec "unsloth/gemma-GGUF:UD-Q6_K_XL"
  if assert_eq "$REPLY_MODEL" "unsloth/gemma-GGUF" && assert_eq "$REPLY_QUANT" "UD-Q6_K_XL"; then
    pass 'parse_model_spec with compound quant'
  else
    fail 'parse_model_spec with compound quant' "got model='$REPLY_MODEL' quant='$REPLY_QUANT'"
  fi
}

# ── extract_quant_from_filename ───────────────────────────────────────────────

test_extract_quant_standard() {
  local result
  result="$(extract_quant_from_filename "model-Q4_K_M.gguf")"
  if assert_eq "$result" "Q4_K_M"; then
    pass 'extract_quant standard Q4_K_M'
  else
    fail 'extract_quant standard Q4_K_M' "expected 'Q4_K_M', got '$result'"
  fi
}

test_extract_quant_with_prefix() {
  local result
  result="$(extract_quant_from_filename "gemma-4-26B-A4B-it-UD-Q6_K.gguf")"
  if assert_eq "$result" "UD-Q6_K"; then
    pass 'extract_quant with UD prefix'
  else
    fail 'extract_quant with UD prefix' "expected 'UD-Q6_K', got '$result'"
  fi
}

test_extract_quant_f16() {
  local result
  result="$(extract_quant_from_filename "model-F16.gguf")"
  if assert_eq "$result" "F16"; then
    pass 'extract_quant F16'
  else
    fail 'extract_quant F16' "expected 'F16', got '$result'"
  fi
}

test_extract_quant_bf16() {
  local result
  result="$(extract_quant_from_filename "model-BF16.gguf")"
  if assert_eq "$result" "BF16"; then
    pass 'extract_quant BF16'
  else
    fail 'extract_quant BF16' "expected 'BF16', got '$result'"
  fi
}

test_extract_quant_sharded() {
  local result
  result="$(extract_quant_from_filename "model-Q4_K_M-00001-of-00003.gguf")"
  if assert_eq "$result" "Q4_K_M"; then
    pass 'extract_quant sharded filename'
  else
    fail 'extract_quant sharded filename' "expected 'Q4_K_M', got '$result'"
  fi
}

test_extract_quant_iq() {
  local result
  result="$(extract_quant_from_filename "model-IQ2_M.gguf")"
  if assert_eq "$result" "IQ2_M"; then
    pass 'extract_quant IQ2_M'
  else
    fail 'extract_quant IQ2_M' "expected 'IQ2_M', got '$result'"
  fi
}

# ── normalize_quant_tag ───────────────────────────────────────────────────────

test_normalize_quant_uppercases() {
  local result
  result="$(normalize_quant_tag "q4_k_m")"
  if assert_eq "$result" "Q4_K_M"; then
    pass 'normalize_quant uppercases'
  else
    fail 'normalize_quant uppercases' "expected 'Q4_K_M', got '$result'"
  fi
}

test_normalize_quant_dashes_to_underscores() {
  local result
  result="$(normalize_quant_tag "UD-Q6-K")"
  if assert_eq "$result" "UD_Q6_K"; then
    pass 'normalize_quant dashes to underscores'
  else
    fail 'normalize_quant dashes to underscores' "expected 'UD_Q6_K', got '$result'"
  fi
}

test_normalize_quant_already_normalized() {
  local result
  result="$(normalize_quant_tag "Q4_K_M")"
  if assert_eq "$result" "Q4_K_M"; then
    pass 'normalize_quant already normalized'
  else
    fail 'normalize_quant already normalized' "expected 'Q4_K_M', got '$result'"
  fi
}

# ── model_name_to_cache_dir ──────────────────────────────────────────────────

test_model_name_to_cache_dir() {
  local result
  result="$(model_name_to_cache_dir "unsloth/gemma-GGUF")"
  if assert_eq "$result" "${HF_HUB_DIR}/models--unsloth--gemma-GGUF"; then
    pass 'model_name_to_cache_dir'
  else
    fail 'model_name_to_cache_dir' "expected '${HF_HUB_DIR}/models--unsloth--gemma-GGUF', got '$result'"
  fi
}

test_model_name_to_cache_dir_invalid() {
  local stderr_file="${TEST_ROOT}/stderr"
  set +e
  (model_name_to_cache_dir "a/b/c" 2>"$stderr_file")
  local status=$?
  set -e
  if [[ $status -ne 0 ]] && assert_contains "$(cat "$stderr_file")" "invalid model name"; then
    pass 'model_name_to_cache_dir rejects invalid'
  else
    fail 'model_name_to_cache_dir rejects invalid' "expected error for invalid model name"
  fi
}

# ── cache_dir_to_model_name ──────────────────────────────────────────────────

test_cache_dir_to_model_name() {
  local result
  result="$(cache_dir_to_model_name "${HF_HUB_DIR}/models--unsloth--gemma-GGUF")"
  if assert_eq "$result" "unsloth/gemma-GGUF"; then
    pass 'cache_dir_to_model_name'
  else
    fail 'cache_dir_to_model_name' "expected 'unsloth/gemma-GGUF', got '$result'"
  fi
}

# ── _find_cached_gguf_files ──────────────────────────────────────────────────

test_find_cached_gguf_files() {
  local cache_dir="${TEST_ROOT}/models--test--model"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"
  touch "${snapshot_dir}/not-a-model.txt"

  local result
  result="$(_find_cached_gguf_files "$cache_dir")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     assert_contains "$result" "model-Q6_K.gguf" && \
     ! assert_contains "$result" "not-a-model.txt" 2>/dev/null; then
    pass 'find_cached_gguf_files returns only gguf'
  else
    fail 'find_cached_gguf_files returns only gguf' "got: $result"
  fi
}

# ── _find_gguf_by_quant ─────────────────────────────────────────────────────

test_find_gguf_by_quant_match() {
  local cache_dir="${TEST_ROOT}/models--test--quant-match"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"

  local result
  result="$(_find_gguf_by_quant "$cache_dir" "Q4_K_M")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     ! assert_contains "$result" "model-Q6_K.gguf" 2>/dev/null; then
    pass 'find_gguf_by_quant matches correct quant'
  else
    fail 'find_gguf_by_quant matches correct quant' "got: $result"
  fi
}

test_find_gguf_by_quant_case_insensitive() {
  local cache_dir="${TEST_ROOT}/models--test--quant-case"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"

  local result
  result="$(_find_gguf_by_quant "$cache_dir" "q4_k_m")"
  if assert_contains "$result" "model-Q4_K_M.gguf"; then
    pass 'find_gguf_by_quant case insensitive'
  else
    fail 'find_gguf_by_quant case insensitive' "got: $result"
  fi
}

# ── cached_quant_tags ────────────────────────────────────────────────────────

test_cached_quant_tags() {
  local cache_dir="${TEST_ROOT}/models--test--tags"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"

  local result
  result="$(cached_quant_tags "$cache_dir")"
  if assert_contains "$result" "Q4_K_M" && assert_contains "$result" "Q6_K"; then
    pass 'cached_quant_tags lists all tags'
  else
    fail 'cached_quant_tags lists all tags' "got: $result"
  fi
}

test_cached_quant_tags_empty() {
  local cache_dir="${TEST_ROOT}/models--test--empty"
  mkdir -p "$cache_dir"

  local result
  result="$(cached_quant_tags "$cache_dir")"
  if assert_eq "$result" ""; then
    pass 'cached_quant_tags empty dir'
  else
    fail 'cached_quant_tags empty dir' "expected empty, got: $result"
  fi
}

# ── cache_has_model_or_quant ─────────────────────────────────────────────────

test_cache_has_model_dir_exists() {
  local cache_dir="${TEST_ROOT}/models--test--has-model"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"

  if cache_has_model_or_quant "$cache_dir" ""; then
    pass 'cache_has_model returns true when dir exists'
  else
    fail 'cache_has_model returns true when dir exists' "expected true"
  fi
}

test_cache_has_model_dir_missing() {
  if ! cache_has_model_or_quant "${TEST_ROOT}/nonexistent" ""; then
    pass 'cache_has_model returns false when dir missing'
  else
    fail 'cache_has_model returns false when dir missing' "expected false"
  fi
}

test_cache_has_quant_match() {
  local cache_dir="${TEST_ROOT}/models--test--has-quant"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"

  if cache_has_model_or_quant "$cache_dir" "Q4_K_M"; then
    pass 'cache_has_quant returns true for matching quant'
  else
    fail 'cache_has_quant returns true for matching quant' "expected true"
  fi
}

test_cache_has_quant_no_match() {
  local cache_dir="${TEST_ROOT}/models--test--no-quant"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"

  if ! cache_has_model_or_quant "$cache_dir" "Q6_K"; then
    pass 'cache_has_quant returns false for non-matching quant'
  else
    fail 'cache_has_quant returns false for non-matching quant' "expected false"
  fi
}

# ── collect_cached_model_entries ─────────────────────────────────────────────

test_collect_cached_model_entries() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/collect-hub"
  local cache_dir="${HF_HUB_DIR}/models--alice--modelA"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/model-Q4_K_M.gguf"

  local result
  result="$(collect_cached_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  if assert_contains "$result" "alice/modelA" && assert_contains "$result" "Q4_K_M"; then
    pass 'collect_cached_model_entries'
  else
    fail 'collect_cached_model_entries' "got: $result"
  fi
}

# ── _validate_profile_name / _validate_template_name ─────────────────────────

test_validate_profile_name_valid() {
  set +e
  _validate_profile_name "my-profile_1" 2>/dev/null
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    pass 'validate_profile_name accepts valid name'
  else
    fail 'validate_profile_name accepts valid name' "expected success"
  fi
}

test_validate_profile_name_invalid() {
  set +e
  (_validate_profile_name "has spaces" 2>/dev/null)
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass 'validate_profile_name rejects invalid name'
  else
    fail 'validate_profile_name rejects invalid name' "expected failure"
  fi
}

test_validate_profile_name_empty() {
  set +e
  (_validate_profile_name "" 2>/dev/null)
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass 'validate_profile_name rejects empty name'
  else
    fail 'validate_profile_name rejects empty name' "expected failure"
  fi
}

test_validate_template_name_valid() {
  set +e
  _validate_template_name "my-template_1" 2>/dev/null
  local status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    pass 'validate_template_name accepts valid name'
  else
    fail 'validate_template_name accepts valid name' "expected success"
  fi
}

test_validate_template_name_invalid() {
  set +e
  (_validate_template_name "bad/name" 2>/dev/null)
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass 'validate_template_name rejects invalid name'
  else
    fail 'validate_template_name rejects invalid name' "expected failure"
  fi
}

# ── _get_builtin_template_content ────────────────────────────────────────────

test_builtin_template_chat() {
  local result
  result="$(_get_builtin_template_content "chat")"
  if assert_contains "$result" "--temp 0.8" && assert_contains "$result" "[llama.cpp]"; then
    pass 'builtin template chat'
  else
    fail 'builtin template chat' "got: $result"
  fi
}

test_builtin_template_code() {
  local result
  result="$(_get_builtin_template_content "code")"
  if assert_contains "$result" "--temp 0.2" && assert_contains "$result" "[llama.cpp.serve]"; then
    pass 'builtin template code'
  else
    fail 'builtin template code' "got: $result"
  fi
}

test_builtin_template_unknown() {
  set +e
  (_get_builtin_template_content "nonexistent" 2>/dev/null)
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass 'builtin template unknown returns error'
  else
    fail 'builtin template unknown returns error' "expected failure"
  fi
}

# ── detect_arch ──────────────────────────────────────────────────────────────

test_detect_arch() {
  local result
  result="$(detect_arch)"
  local expected
  expected="$(expected_arch)"
  if assert_eq "$result" "$expected"; then
    pass 'detect_arch matches expected'
  else
    fail 'detect_arch matches expected' "expected '$expected', got '$result'"
  fi
}

# ── backend resolution helpers ───────────────────────────────────────────────

test_platform_default_backend_macos_arm64() {
  local result
  local mock_bin="${TEST_ROOT}/mock-uname-darwin"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *)  echo "Darwin" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  result="$(PATH="${mock_bin}:$PATH" _platform_default_backend)"
  if assert_eq "$result" "mlx"; then
    pass 'platform default backend is mlx on Darwin/arm64'
  else
    fail 'platform default backend is mlx on Darwin/arm64' "expected 'mlx', got '$result'"
  fi
}

test_platform_default_backend_non_macos_arm64() {
  local result
  local mock_bin="${TEST_ROOT}/mock-uname-linux"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
  *)  echo "Linux" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  result="$(PATH="${mock_bin}:$PATH" _platform_default_backend)"
  if assert_eq "$result" "llama.cpp"; then
    pass 'platform default backend is llama.cpp on non-Darwin/arm64'
  else
    fail 'platform default backend is llama.cpp on non-Darwin/arm64' "expected 'llama.cpp', got '$result'"
  fi
}

test_resolve_backend_prefers_flag() {
  local result
  result="$(resolve_backend "mlx")"
  if assert_eq "$result" "mlx"; then
    pass 'resolve_backend prefers explicit flag over platform default'
  else
    fail 'resolve_backend prefers explicit flag over platform default' "expected 'mlx', got '$result'"
  fi
}

test_resolve_backend_falls_back_to_platform_default() {
  local result
  result="$(resolve_backend "")"
  # Test runs on whatever the host platform is; just verify it returns a valid backend.
  case "$result" in
    mlx|llama.cpp) pass 'resolve_backend falls back to platform default when flag is empty' ;;
    *) fail 'resolve_backend falls back to platform default when flag is empty' "expected mlx or llama.cpp, got '$result'" ;;
  esac
}

test_resolve_backend_rejects_invalid_value() {
  local stderr_file="${TEST_ROOT}/stderr.backend"
  set +e
  (resolve_backend "bad" 2>"$stderr_file")
  local status=$?
  set -e
  if [[ $status -ne 0 ]] && assert_contains "$(cat "$stderr_file")" "unknown backend"; then
    pass 'resolve_backend rejects invalid backend values'
  else
    fail 'resolve_backend rejects invalid backend values' "expected invalid backend error"
  fi
}

test_print_tsv_table_dynamic_widths() {
  local result
  result="$(_print_tsv_table 'lrr' $'MODEL\tDOWNLOADS\tLIKES' <<'EOF'
short	12	3
much-longer-model	4	55
EOF
)"

  local expected
  expected="$(cat <<'EOF'
MODEL              DOWNLOADS  LIKES
-----------------  ---------  -----
short                     12      3
much-longer-model          4     55
EOF
)"

  if assert_eq "$result" "$expected"; then
    pass 'print_tsv_table sizes columns dynamically'
  else
    fail 'print_tsv_table sizes columns dynamically' "unexpected table output: $result"
  fi
}

# ── _is_mlx_platform ─────────────────────────────────────────────────────────

test_is_mlx_platform_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-platform"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *)  echo "Darwin" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  if PATH="${mock_bin}:$PATH" _is_mlx_platform; then
    pass '_is_mlx_platform returns true on Darwin/arm64'
  else
    fail '_is_mlx_platform returns true on Darwin/arm64' "expected true on Darwin/arm64"
  fi
}

test_is_mlx_platform_non_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-linux-platform"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
  *)  echo "Linux" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  set +e
  PATH="${mock_bin}:$PATH" _is_mlx_platform
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass '_is_mlx_platform returns false on Linux/x86_64'
  else
    fail '_is_mlx_platform returns false on Linux/x86_64' "expected false on Linux/x86_64"
  fi
}

# ── _infer_model_backend ──────────────────────────────────────────────────────

# Helper: create a fake GGUF file in the unit-test HF cache.
_create_unit_gguf_fixture() {
  local model_name="$1"
  local gguf_filename="$2"
  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/${gguf_filename}"
}

test_infer_model_backend_cached_gguf() {
  _create_unit_gguf_fixture "unsloth/Llama-3-8B-GGUF" "model-Q4_K_M.gguf"
  local result
  result="$(_infer_model_backend "unsloth/Llama-3-8B-GGUF:Q4_K_M")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_model_backend cached GGUF files → llama.cpp'
  else
    fail '_infer_model_backend cached GGUF files → llama.cpp' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_model_backend_cached_mlx() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-infer-cache-mlx"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *)  echo "Darwin" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  local model_name='someorg/Qwen3-8B-4bit'
  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"
  mkdir -p "${cache_dir}/snapshots/abc123"
  : >"${cache_dir}/snapshots/abc123/model.safetensors"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_model_backend "$model_name")"
  if assert_eq "$result" "mlx"; then
    pass '_infer_model_backend cached non-GGUF model → mlx'
  else
    fail '_infer_model_backend cached non-GGUF model → mlx' "expected 'mlx', got '$result'"
  fi
}

test_infer_model_backend_cached_mlx_on_linux() {
  local mock_bin="${TEST_ROOT}/mock-uname-linux-infer-cache-mlx"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
  *)  echo "Linux" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  local model_name='someorg/gemma-4-26b-a4b-it-4bit'
  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"
  mkdir -p "${cache_dir}/snapshots/abc123"
  : >"${cache_dir}/snapshots/abc123/model.safetensors"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_model_backend "$model_name")"
  if assert_eq "$result" "mlx"; then
    pass '_infer_model_backend cached non-GGUF model on Linux → mlx'
  else
    fail '_infer_model_backend cached non-GGUF model on Linux → mlx' "expected 'mlx', got '$result'"
  fi
}

test_infer_model_backend_uncached_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-infer"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Darwin" ;;
  -m) echo "arm64" ;;
  *)  echo "Darwin" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_model_backend "bartowski/Qwen3-8B-4bit")"
  if assert_eq "$result" "mlx"; then
    pass '_infer_model_backend uncached model on arm64 → platform default (mlx)'
  else
    fail '_infer_model_backend uncached model on arm64 → platform default (mlx)' "expected 'mlx', got '$result'"
  fi
}

test_infer_model_backend_uncached_linux() {
  local mock_bin="${TEST_ROOT}/mock-uname-linux-infer"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
  *)  echo "Linux" ;;
esac
EOF
  chmod +x "${mock_bin}/uname"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_model_backend "someuser/SomeModel-4bit")"
  if assert_eq "$result" "mlx"; then
    pass '_infer_model_backend uncached USER/MODEL on Linux → mlx assumption'
  else
    fail '_infer_model_backend uncached USER/MODEL on Linux → mlx assumption' "expected 'mlx', got '$result'"
  fi
}

# ── _section_matches ──────────────────────────────────────────────────────────

test_section_matches_common_always() {
  if _section_matches "common" "run" "mlx" && _section_matches "common" "" ""; then
    pass '_section_matches common always matches'
  else
    fail '_section_matches common always matches' "common should match any mode/backend"
  fi
}

test_section_matches_command_sections() {
  local ok=true
  _section_matches "run" "run" "mlx" || ok=false
  _section_matches "run" "run" "llama.cpp" || ok=false
  _section_matches "run" "" "" || ok=false
  _section_matches "serve" "serve" "mlx" || ok=false
  if _section_matches "run" "serve" "mlx"; then ok=false; fi
  if _section_matches "serve" "run" "llama.cpp"; then ok=false; fi

  if [[ "$ok" == true ]]; then
    pass '_section_matches command sections filter by mode'
  else
    fail '_section_matches command sections filter by mode' "unexpected matching result"
  fi
}

test_section_matches_backend_sections() {
  local ok=true
  _section_matches "mlx" "run" "mlx" || ok=false
  _section_matches "mlx" "serve" "mlx" || ok=false
  _section_matches "mlx" "" "" || ok=false
  _section_matches "llama.cpp" "run" "llama.cpp" || ok=false
  if _section_matches "mlx" "run" "llama.cpp"; then ok=false; fi
  if _section_matches "llama.cpp" "serve" "mlx"; then ok=false; fi

  if [[ "$ok" == true ]]; then
    pass '_section_matches backend sections filter by backend'
  else
    fail '_section_matches backend sections filter by backend' "unexpected matching result"
  fi
}

test_section_matches_compound_sections() {
  local ok=true
  _section_matches "mlx.run" "run" "mlx" || ok=false
  _section_matches "llama.cpp.serve" "serve" "llama.cpp" || ok=false
  if _section_matches "mlx.run" "serve" "mlx"; then ok=false; fi
  if _section_matches "mlx.run" "run" "llama.cpp"; then ok=false; fi
  if _section_matches "llama.cpp.serve" "run" "llama.cpp"; then ok=false; fi
  if _section_matches "llama.cpp.run" "run" "mlx"; then ok=false; fi

  if [[ "$ok" == true ]]; then
    pass '_section_matches compound sections filter by both'
  else
    fail '_section_matches compound sections filter by both' "unexpected matching result"
  fi
}

# ── collect_template_entries ──────────────────────────────────────────────────

test_collect_template_entries_includes_builtins() {
  local result
  result="$(collect_template_entries)"
  if assert_contains "$result" "chat|built-in" && assert_contains "$result" "code|built-in"; then
    pass 'collect_template_entries includes built-in chat and code'
  else
    fail 'collect_template_entries includes built-in chat and code' "got: $result"
  fi
}

# ── _completions_fish ───────────────────────────────────────────────────────

test_completions_fish_generation() {
  local out
  out="$(_completions_fish)"

  if ! assert_contains "$out" "for tok in \$argv"; then
    fail '_completions_fish generates fish variables literally' "expected literal \$argv in generated fish completion script"
    return
  fi

  if ! assert_contains "$out" "if test \"\$tok\" = \"--backend\""; then
    fail '_completions_fish generates fish backend parsing block' 'expected backend parsing block in generated fish completion script'
    return
  fi

  if assert_contains "$out" "run serve; and test (__corral_runtime_backend) = mlx\" -a \"(__corral_cached_models_no_quant) (__corral_profiles)\" -d 'Model id or profile'"; then
    fail '_completions_fish run/serve suggestions have no per-item description noise' 'did not expect per-item description for run/serve candidates'
    return
  fi

  pass '_completions_fish generates fish script under set -u'
}

test_completions_fish_profile_set_positionals() {
  local out
  out="$(_completions_fish)"

  if ! assert_contains "$out" 'complete -c corral -n "__corral_profile_set_needs_target" -a "(__corral_templates) (__corral_cached_models)"'; then
    fail '_completions_fish completes profile set target from templates and models' 'expected profile set target completion line in generated fish script'
    return
  fi

  if ! assert_contains "$out" 'complete -c corral -n "__corral_profile_set_needs_model" -a "(__corral_cached_models)"'; then
    fail '_completions_fish completes profile set model after template' 'expected profile set model completion line in generated fish script'
    return
  fi

  pass '_completions_fish completes profile set template/model positionals'
}

test_completions_zsh_profile_template_filtering() {
  local out
  out="$(_completions_zsh)"

  if ! assert_contains "$out" "corral ls --quiet --profiles 2>/dev/null | awk 'NF == 1 && index(\$0, \" \") == 0 { print \$0 }'"; then
    fail '_completions_zsh filters sentinel profile lines' 'expected profile filtering awk pipeline in zsh completion script'
    return
  fi

  if ! assert_contains "$out" "corral ls --quiet --templates 2>/dev/null | awk 'NF == 1 && index(\$0, \" \") == 0 { print \$0 }'"; then
    fail '_completions_zsh filters sentinel template lines' 'expected template filtering awk pipeline in zsh completion script'
    return
  fi

  pass '_completions_zsh filters profile/template sentinel lines'
}

test_completions_zsh_profile_set_positionals() {
  local out
  out="$(_completions_zsh)"

  if ! assert_contains "$out" "_alternative 'templates:template:_corral_templates' 'models:model:_corral_cached_models'"; then
    fail '_completions_zsh completes profile set target from templates and models' 'expected zsh profile set target completion alternative'
    return
  fi

  if ! assert_contains "$out" "if _corral_has_template \"\$words[4]\"; then"; then
    fail '_completions_zsh completes profile set model after template' 'expected zsh template-aware model completion block'
    return
  fi

  pass '_completions_zsh completes profile set template/model positionals'
}

test_completions_bash_profile_template_filtering() {
  local completions_file
  local profile_filter
  local template_filter
  completions_file="$(dirname "${BASH_SOURCE[0]}")/../src/lib/corral-completions.sh"

  profile_filter="$(cat <<'EOF'
done < <(corral ls --quiet --profiles 2>/dev/null | awk 'NF == 1 && index(\$0, " ") == 0 { print \$0 }')
EOF
)"
  template_filter="$(cat <<'EOF'
done < <(corral ls --quiet --templates 2>/dev/null | awk 'NF == 1 && index(\$0, " ") == 0 { print \$0 }')
EOF
)"

  if ! grep -Fq "$profile_filter" "$completions_file"; then
    fail '_completions_bash filters sentinel profile lines' 'expected profile filtering awk pipeline in bash completion script'
    return
  fi

  if ! grep -Fq "$template_filter" "$completions_file"; then
    fail '_completions_bash filters sentinel template lines' 'expected template filtering awk pipeline in bash completion script'
    return
  fi

  pass '_completions_bash filters profile/template sentinel lines'
}

test_completions_bash_profile_set_positionals() {
  local out
  out="$(_completions_bash)"

  if ! assert_contains "$out" "elif [[ \$COMP_CWORD -eq 4 ]]; then"; then
    fail '_completions_bash completes profile set target from templates and models' 'expected bash target position branch for profile set'
    return
  fi

  if ! assert_contains "$out" "COMPREPLY=(\$(compgen -W \"\$templates_words \$models_words\" -- \"\$cur\"))"; then
    fail '_completions_bash completes profile set target from templates and models' 'expected bash target completion list for profile set'
    return
  fi

  if ! assert_contains "$out" "if [[ \$target_is_template -eq 1 ]]; then"; then
    fail '_completions_bash completes profile set model after template' 'expected bash template-aware model completion block'
    return
  fi

  pass '_completions_bash completes profile set template/model positionals'
}

# ── run tests ────────────────────────────────────────────────────────────────

test_parse_model_spec_without_quant
test_parse_model_spec_with_quant
test_parse_model_spec_with_compound_quant
test_extract_quant_standard
test_extract_quant_with_prefix
test_extract_quant_f16
test_extract_quant_bf16
test_extract_quant_sharded
test_extract_quant_iq
test_normalize_quant_uppercases
test_normalize_quant_dashes_to_underscores
test_normalize_quant_already_normalized
test_model_name_to_cache_dir
test_model_name_to_cache_dir_invalid
test_cache_dir_to_model_name
test_find_cached_gguf_files
test_find_gguf_by_quant_match
test_find_gguf_by_quant_case_insensitive
test_cached_quant_tags
test_cached_quant_tags_empty
test_cache_has_model_dir_exists
test_cache_has_model_dir_missing
test_cache_has_quant_match
test_cache_has_quant_no_match
test_collect_cached_model_entries
test_validate_profile_name_valid
test_validate_profile_name_invalid
test_validate_profile_name_empty
test_validate_template_name_valid
test_validate_template_name_invalid
test_builtin_template_chat
test_builtin_template_code
test_builtin_template_unknown
test_detect_arch
test_platform_default_backend_macos_arm64
test_platform_default_backend_non_macos_arm64
test_resolve_backend_prefers_flag
test_resolve_backend_falls_back_to_platform_default
test_resolve_backend_rejects_invalid_value
test_print_tsv_table_dynamic_widths
test_is_mlx_platform_arm64
test_is_mlx_platform_non_arm64
test_infer_model_backend_cached_gguf
test_infer_model_backend_cached_mlx
test_infer_model_backend_cached_mlx_on_linux
test_infer_model_backend_uncached_arm64
test_infer_model_backend_uncached_linux
test_section_matches_common_always
test_section_matches_command_sections
test_section_matches_backend_sections
test_section_matches_compound_sections
test_collect_template_entries_includes_builtins
test_completions_fish_generation
test_completions_fish_profile_set_positionals
test_completions_zsh_profile_template_filtering
test_completions_zsh_profile_set_positionals
test_completions_bash_profile_template_filtering
test_completions_bash_profile_set_positionals

report_results
