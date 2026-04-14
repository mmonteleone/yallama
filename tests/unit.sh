#!/usr/bin/env bash
# Unit tests for pure helper functions (yallama-cache.sh, yallama-helpers.sh).
# These tests exercise functions directly without running yallama as a subprocess.

# shellcheck source=tests/test-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Override HOME/HF_HUB_DIR for isolation.
HOME="$(mktemp -d "${TEST_ROOT}/home.XXXXXX")"
HF_HUB_DIR="${HOME}/.cache/huggingface/hub"

source_yallama_libs

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
  if assert_contains "$result" "--temp 0.8" && assert_contains "$result" "--ctx-size 8192"; then
    pass 'builtin template chat'
  else
    fail 'builtin template chat' "got: $result"
  fi
}

test_builtin_template_code() {
  local result
  result="$(_get_builtin_template_content "code")"
  if assert_contains "$result" "--temp 0.2" && assert_contains "$result" "[serve]"; then
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

report_results
