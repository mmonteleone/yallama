#!/usr/bin/env bash
# Unit tests for pure helper functions (corral-cache.sh, corral-helpers.sh).
# These tests exercise functions directly without running corral as a subprocess.

# shellcheck source=tests/test-helpers.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-helpers.sh"

# Override HOME/HF_HUB_DIR for isolation.
HOME="$(mktemp -d "${TEST_ROOT}/home.XXXXXX")"
HF_HUB_DIR="${HOME}/.cache/huggingface/hub"

source_corral_libs

# ── parse_model_spec ──────────────────────────────────────────────────────────

test_parse_model_spec_without_quant() {
  parse_model_spec "user/model"
  if assert_eq "$REPLY_MODEL" "user/model" && assert_eq "$REPLY_QUANT" ""; then
    pass 'parse_model_spec without quant'
  else
    fail 'parse_model_spec without quant' "got model='$REPLY_MODEL' quant='$REPLY_QUANT'"
  fi
}

test_parse_model_spec_with_quant() {
  parse_model_spec "user/model:Q4_K_M"
  if assert_eq "$REPLY_MODEL" "user/model" && assert_eq "$REPLY_QUANT" "Q4_K_M"; then
    pass 'parse_model_spec with quant'
  else
    fail 'parse_model_spec with quant' "got model='$REPLY_MODEL' quant='$REPLY_QUANT'"
  fi
}

test_parse_model_spec_with_compound_quant() {
  parse_model_spec "unsloth/gemma-GGUF:UD-Q6_K_XL"
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

# ── find_cached_gguf_files ───────────────────────────────────────────────────

test_find_cached_gguf_files() {
  local cache_dir="${TEST_ROOT}/models--test--model"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"
  touch "${snapshot_dir}/not-a-model.txt"

  local result
  result="$(find_cached_gguf_files "$cache_dir")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     assert_contains "$result" "model-Q6_K.gguf" && \
     ! assert_contains "$result" "not-a-model.txt" 2>/dev/null; then
    pass 'find_cached_gguf_files returns only gguf'
  else
    fail 'find_cached_gguf_files returns only gguf' "got: $result"
  fi
}

test_find_cached_gguf_files_ignores_mmproj_sidecars() {
  local cache_dir="${TEST_ROOT}/models--test--mmproj"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/mmproj-BF16.gguf"

  local result
  result="$(find_cached_gguf_files "$cache_dir")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     ! assert_contains "$result" "mmproj-BF16.gguf" 2>/dev/null; then
    pass 'find_cached_gguf_files ignores mmproj sidecars'
  else
    fail 'find_cached_gguf_files ignores mmproj sidecars' "got: $result"
  fi
}

test_find_cached_gguf_files_ignores_suffix_mmproj_sidecars() {
  local cache_dir="${TEST_ROOT}/models--test--suffix-mmproj"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/gemma-4-26B-it-mmproj.gguf"

  local result
  result="$(find_cached_gguf_files "$cache_dir")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     ! assert_contains "$result" "gemma-4-26B-it-mmproj.gguf" 2>/dev/null; then
    pass 'find_cached_gguf_files ignores suffix mmproj sidecars'
  else
    fail 'find_cached_gguf_files ignores suffix mmproj sidecars' "got: $result"
  fi
}

test_find_cached_gguf_files_ignores_mtp_sidecars() {
  local cache_dir="${TEST_ROOT}/models--test--mtp"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/mtp-model-Q4_0.gguf"

  local result
  result="$(find_cached_gguf_files "$cache_dir")"
  if assert_contains "$result" "model-Q4_K_M.gguf" && \
     ! assert_contains "$result" "mtp-model-Q4_0.gguf" 2>/dev/null; then
    pass 'find_cached_gguf_files ignores mtp sidecars'
  else
    fail 'find_cached_gguf_files ignores mtp sidecars' "got: $result"
  fi
}

# ── find_gguf_by_quant ──────────────────────────────────────────────────────

test_find_gguf_by_quant_match() {
  local cache_dir="${TEST_ROOT}/models--test--quant-match"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"

  local result
  result="$(find_gguf_by_quant "$cache_dir" "Q4_K_M")"
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
  result="$(find_gguf_by_quant "$cache_dir" "q4_k_m")"
  if assert_contains "$result" "model-Q4_K_M.gguf"; then
    pass 'find_gguf_by_quant case insensitive'
  else
    fail 'find_gguf_by_quant case insensitive' "got: $result"
  fi
}

# ── _cached_quant_tags ───────────────────────────────────────────────────────

test_cached_quant_tags() {
  local cache_dir="${TEST_ROOT}/models--test--tags"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  touch "${snapshot_dir}/model-Q4_K_M.gguf"
  touch "${snapshot_dir}/model-Q6_K.gguf"

  local result
  result="$(_cached_quant_tags "$cache_dir")"
  if assert_contains "$result" "Q4_K_M" && assert_contains "$result" "Q6_K"; then
    pass '_cached_quant_tags lists all tags'
  else
    fail '_cached_quant_tags lists all tags' "got: $result"
  fi
}

test_cached_quant_tags_empty() {
  local cache_dir="${TEST_ROOT}/models--test--empty"
  mkdir -p "$cache_dir"

  local result
  result="$(_cached_quant_tags "$cache_dir")"
  if assert_eq "$result" ""; then
    pass '_cached_quant_tags empty dir'
  else
    fail '_cached_quant_tags empty dir' "expected empty, got: $result"
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
  printf 'x' > "${snapshot_dir}/mmproj-BF16.gguf"
  printf 'x' > "${snapshot_dir}/mtp-modelA.gguf"

  local result
  result="$(collect_cached_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  if assert_contains "$result" "alice/modelA" && \
     assert_contains "$result" "Q4_K_M" && \
     ! assert_contains "$result" "mmproj-BF16" 2>/dev/null && \
     ! assert_contains "$result" "mtp-modelA" 2>/dev/null; then
    pass 'collect_cached_model_entries'
  else
    fail 'collect_cached_model_entries' "got: $result"
  fi
}

test_collect_cached_model_entries_deduplicates_shared_snapshot_blobs() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/collect-shared-blob-hub"
  local cache_dir="${HF_HUB_DIR}/models--alice--shared-model"
  local blob_dir="${cache_dir}/blobs"
  local blob_path="${blob_dir}/shared-q4-k-m"
  local snapshot_one="${cache_dir}/snapshots/abc123"
  local snapshot_two="${cache_dir}/snapshots/def456"
  mkdir -p "$blob_dir" "$snapshot_one" "$snapshot_two"
  dd if=/dev/zero of="$blob_path" bs=1024 count=2 2>/dev/null
  ln -s "../../blobs/shared-q4-k-m" "${snapshot_one}/shared-Q4_K_M.gguf"
  ln -s "../../blobs/shared-q4-k-m" "${snapshot_two}/shared-Q4_K_M.gguf"

  local expected_size
  expected_size="$(du -sh "$blob_path" | cut -f1)"
  local result
  result="$(collect_cached_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  local size="${result#*|}"
  size="${size#*|}"
  size="${size%%|*}"
  if assert_eq "$size" "$expected_size"; then
    pass 'collect_cached_model_entries deduplicates shared snapshot blobs'
  else
    fail 'collect_cached_model_entries deduplicates shared snapshot blobs' "expected size='$expected_size', got: $result"
  fi
}

test_collect_mlx_model_entries_includes_safetensors_cache() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/collect-mlx-hub"
  local cache_dir="${HF_HUB_DIR}/models--unsloth--Qwen3.8-27B-UD-MLX-4bit"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/model.safetensors"

  local result
  result="$(collect_mlx_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  if assert_contains "$result" 'unsloth/Qwen3.8-27B-UD-MLX-4bit' && assert_contains "$result" '|mlx'; then
    pass 'collect_mlx_model_entries includes safetensors cache'
  else
    fail 'collect_mlx_model_entries includes safetensors cache' "got: $result"
  fi
}

test_collect_mlx_model_entries_ignores_gguf_cache() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/collect-mlx-ignore-gguf"
  local cache_dir="${HF_HUB_DIR}/models--unsloth--Qwen3.8-27B-GGUF"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/model-Q4_K_M.gguf"

  local result
  result="$(collect_mlx_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  if ! assert_contains "$result" 'unsloth/Qwen3.8-27B-GGUF'; then
    pass 'collect_mlx_model_entries ignores gguf cache'
  else
    fail 'collect_mlx_model_entries ignores gguf cache' "got: $result"
  fi
}

test_collect_mlx_model_entries_ignores_no_weights_cache() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/collect-mlx-no-weights"
  local cache_dir="${HF_HUB_DIR}/models--unsloth--Qwen3.8-27B-Empty"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/README.md"

  local result
  result="$(collect_mlx_model_entries)"
  HF_HUB_DIR="$old_hf_hub_dir"

  if ! assert_contains "$result" 'unsloth/Qwen3.8-27B-Empty'; then
    pass 'collect_mlx_model_entries ignores cache without model weights'
  else
    fail 'collect_mlx_model_entries ignores cache without model weights' "got: $result"
  fi
}

# ── _infer_remove_backend ───────────────────────────────────────────────────

test_infer_remove_backend_quant_suffix() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-remove-quant"
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
  result="$(PATH="${mock_bin}:$PATH" _infer_remove_backend "demo/model:Q4_K_M")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_remove_backend quant suffix -> llama.cpp'
  else
    fail '_infer_remove_backend quant suffix -> llama.cpp' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_remove_backend_cached_gguf_on_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-remove-gguf"
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

  local model_name='HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive'
  _create_unit_gguf_fixture "$model_name" "model-Q4_K_M.gguf"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_remove_backend "$model_name")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_remove_backend cached GGUF on arm64 -> llama.cpp'
  else
    fail '_infer_remove_backend cached GGUF on arm64 -> llama.cpp' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_remove_backend_cached_mlx_on_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-remove-mlx"
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

  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/remove-mlx-hub"
  local cache_dir="${HF_HUB_DIR}/models--mlx-community--Qwen3-8B-4bit"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/model.safetensors"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_remove_backend "mlx-community/Qwen3-8B-4bit")"
  HF_HUB_DIR="$old_hf_hub_dir"

  if assert_eq "$result" "mlx"; then
    pass '_infer_remove_backend cached MLX on arm64 -> mlx'
  else
    fail '_infer_remove_backend cached MLX on arm64 -> mlx' "expected 'mlx', got '$result'"
  fi
}

test_infer_remove_backend_rejects_mixed_cache() {
  local old_hf_hub_dir="$HF_HUB_DIR"
  HF_HUB_DIR="${TEST_ROOT}/remove-mixed-hub"
  local cache_dir="${HF_HUB_DIR}/models--demo--mixed-model"
  local snapshot_dir="${cache_dir}/snapshots/abc123"
  mkdir -p "$snapshot_dir"
  printf 'x' > "${snapshot_dir}/model-Q4_K_M.gguf"
  printf 'x' > "${snapshot_dir}/model.safetensors"

  local stderr_file="${TEST_ROOT}/stderr-remove-mixed"
  set +e
  (_infer_remove_backend 'demo/mixed-model' 2>"$stderr_file")
  local status=$?
  set -e
  HF_HUB_DIR="$old_hf_hub_dir"

  if [[ $status -ne 0 ]] && assert_contains "$(cat "$stderr_file")" 'has both GGUF and MLX cache entries'; then
    pass '_infer_remove_backend rejects mixed cache without explicit backend'
  else
    fail '_infer_remove_backend rejects mixed cache without explicit backend' "expected ambiguity error, got status=$status stderr='$(cat "$stderr_file" 2>/dev/null)'"
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

test_builtin_template_gemma() {
  local result
  result="$(_get_builtin_template_content "gemma")"
  if assert_contains "$result" "--temp 1.0" && assert_contains "$result" "[llama.cpp]"; then
    pass 'builtin template gemma'
  else
    fail 'builtin template gemma' "got: $result"
  fi
}

test_builtin_template_qwen() {
  local result
  result="$(_get_builtin_template_content "qwen")"
  if assert_contains "$result" "--temp 1.0" && assert_contains "$result" "[llama.cpp.serve]"; then
    pass 'builtin template qwen'
  else
    fail 'builtin template qwen' "got: $result"
  fi
}

test_builtin_template_glimmer() {
  local result
  result="$(_get_builtin_template_content "glimmer")"
  if assert_contains "$result" "model=meta-models/Muse-Glimmer-30B-GGUF:Q4_K_M" && \
     assert_contains "$result" "[mlx.serve]" && \
     assert_contains "$result" "--reasoning auto"; then
    pass 'builtin template glimmer'
  else
    fail 'builtin template glimmer' "got: $result"
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

# ── _detect_arch ─────────────────────────────────────────────────────────────

test_detect_arch() {
  local result
  result="$(_detect_arch)"
  local expected
  expected="$(expected_arch)"
  if assert_eq "$result" "$expected"; then
    pass '_detect_arch matches expected'
  else
    fail '_detect_arch matches expected' "expected '$expected', got '$result'"
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

  result="$(PATH="${mock_bin}:$PATH" platform_default_backend)"
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

  result="$(PATH="${mock_bin}:$PATH" platform_default_backend)"
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

# ── path normalization helpers ──────────────────────────────────────────────

test_normalize_dir_path_expands_tilde_and_strips_trailing_slash() {
  local result
  result="$(normalize_dir_path "~/corral-test/")"
  if assert_eq "$result" "${HOME}/corral-test"; then
    pass 'normalize_dir_path expands tilde and strips trailing slash'
  else
    fail 'normalize_dir_path expands tilde and strips trailing slash' "expected '${HOME}/corral-test', got '$result'"
  fi
}

test_normalize_dir_path_preserves_root() {
  local result
  result="$(normalize_dir_path "/")"
  if assert_eq "$result" "/"; then
    pass 'normalize_dir_path preserves root path'
  else
    fail 'normalize_dir_path preserves root path' "expected '/', got '$result'"
  fi
}

test_print_tsv_table_dynamic_widths() {
  local result
  result="$(print_tsv_table 'lrr' $'MODEL\tDOWNLOADS\tLIKES' <<'EOF'
short	12	3
much-longer-model	4	55
EOF
)"

  local expected
  expected="$(cat <<'EOF'
MODEL              DOWNLOADS  LIKES
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

test_print_tsv_table_ignores_ansi_width() {
  local result
  result="$(print_tsv_table 'lll' $'MODEL\tBACKEND\tSIZE' <<EOF
demo/test-GGUF	llama.cpp	${ANSI_COLOR_GREEN}2.0K${ANSI_COLOR_RESET}
demo/test-GGUF:Q8_0	llama.cpp	${ANSI_COLOR_GREEN}4.0K${ANSI_COLOR_RESET}
EOF
)"

  if assert_contains "$result" "demo/test-GGUF       llama.cpp  ${ANSI_COLOR_GREEN}2.0K${ANSI_COLOR_RESET}" && \
     assert_contains "$result" "demo/test-GGUF:Q8_0  llama.cpp  ${ANSI_COLOR_GREEN}4.0K${ANSI_COLOR_RESET}"; then
    pass 'print_tsv_table ignores ansi for width'
  else
    fail 'print_tsv_table ignores ansi for width' "unexpected ANSI-aware table output: $result"
  fi
}

test_ansi_color_returns_named_escape_sequence() {
  local result
  result="$(_ansi_color cyan)"

  if assert_eq "$result" "$ANSI_COLOR_CYAN"; then
    pass 'ansi_color returns named escape sequence'
  else
    fail 'ansi_color returns named escape sequence' 'expected cyan ANSI escape sequence'
  fi
}

test_wrap_color_applies_named_escape_sequence() {
  local result
  result="$(wrap_color green '2.0K')"

  if assert_eq "$result" "${ANSI_COLOR_GREEN}2.0K${ANSI_COLOR_RESET}"; then
    pass 'wrap_color applies named escape sequence'
  else
    fail 'wrap_color applies named escape sequence' 'expected wrapped green text'
  fi
}

test_wrap_stdout_color_is_plain_without_tty() {
  local stdout_file="${TEST_ROOT}/stdout.color-plain"
  local result
  result="$(_wrap_stdout_color cyan 'MODEL' >"$stdout_file"; cat "$stdout_file")"

  if assert_eq "$result" 'MODEL'; then
    pass 'wrap_stdout_color leaves text plain without tty'
  else
    fail 'wrap_stdout_color leaves text plain without tty' "expected plain text, got '$result'"
  fi
}

test_stdout_supports_color_disabled_without_tty() {
  local stdout_file="${TEST_ROOT}/stdout.no-tty"
  if ! (stdout_supports_color >"$stdout_file"); then
    pass 'stdout_supports_color disables color without tty'
  else
    fail 'stdout_supports_color disables color without tty' 'expected non-tty stdout to disable color'
  fi
}

test_stdout_supports_color_disabled_by_no_color() {
  local tty_probe="[[ -t 1 ]]"
  if script -q /dev/null bash -lc "source '${ROOT_DIR}/src/lib/corral-helpers.sh'; NO_COLOR=1; ${tty_probe}; stdout_supports_color" >/dev/null 2>&1; then
    fail 'stdout_supports_color honors NO_COLOR' 'expected NO_COLOR to disable color output'
  else
    pass 'stdout_supports_color honors NO_COLOR'
  fi
}

test_stdout_supports_color_disabled_for_dumb_term() {
  local tty_probe="[[ -t 1 ]]"
  if script -q /dev/null env TERM=dumb bash -lc "source '${ROOT_DIR}/src/lib/corral-helpers.sh'; ${tty_probe}; stdout_supports_color" >/dev/null 2>&1; then
    fail 'stdout_supports_color disables color for dumb term' 'expected TERM=dumb to disable color output'
  else
    pass 'stdout_supports_color disables color for dumb term'
  fi
}

# ── is_mlx_platform ──────────────────────────────────────────────────────────

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

  if PATH="${mock_bin}:$PATH" is_mlx_platform; then
    pass 'is_mlx_platform returns true on Darwin/arm64'
  else
    fail 'is_mlx_platform returns true on Darwin/arm64' "expected true on Darwin/arm64"
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
  PATH="${mock_bin}:$PATH" is_mlx_platform
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    pass 'is_mlx_platform returns false on Linux/x86_64'
  else
    fail 'is_mlx_platform returns false on Linux/x86_64' "expected false on Linux/x86_64"
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

_create_unit_profile_fixture() {
  local profile_name="$1"
  local content="$2"
  local profiles_dir
  profiles_dir="$(_profiles_dir)"
  mkdir -p "$profiles_dir"
  printf '%s\n' "$content" >"${profiles_dir}/${profile_name}"
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

# ── _infer_pull_backend ──────────────────────────────────────────────────────

test_infer_pull_backend_gguf_suffix() {
  local result
  result="$(_infer_pull_backend "unsloth/gemma-4-27B-it-GGUF")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_pull_backend -GGUF repo name → llama.cpp'
  else
    fail '_infer_pull_backend -GGUF repo name → llama.cpp' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_pull_backend_quant_specifier() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-pull-quant"
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
  # A quant specifier unambiguously means GGUF even on arm64 where platform
  # default would otherwise be mlx.
  result="$(PATH="${mock_bin}:$PATH" _infer_pull_backend "user/some-model:Q4_K_M")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_pull_backend quant specifier → llama.cpp regardless of platform'
  else
    fail '_infer_pull_backend quant specifier → llama.cpp regardless of platform' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_pull_backend_remote_gguf_metadata() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-pull-remote-gguf"
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

  cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
if [[ "$url" == "https://huggingface.co/api/models/HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive" ]]; then
  cat <<'JSON'
{
  "tags": ["gguf", "qwen"],
  "siblings": [
    {"rfilename": "Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"}
  ]
}
JSON
  exit 0
fi
echo "unexpected URL: $url" >&2
exit 1
EOF
  chmod +x "${mock_bin}/curl"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_pull_backend "HauhauCS/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive")"
  if assert_eq "$result" "llama.cpp"; then
    pass '_infer_pull_backend remote GGUF metadata → llama.cpp'
  else
    fail '_infer_pull_backend remote GGUF metadata → llama.cpp' "expected 'llama.cpp', got '$result'"
  fi
}

test_infer_pull_backend_mlx_model_arm64() {
  local mock_bin="${TEST_ROOT}/mock-uname-arm64-pull-mlx"
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

  cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{}\n'
EOF
  chmod +x "${mock_bin}/curl"

  local result
  result="$(PATH="${mock_bin}:$PATH" _infer_pull_backend "mlx-community/Qwen3-8B-4bit")"
  if assert_eq "$result" "mlx"; then
    pass '_infer_pull_backend plain MLX model on arm64 → mlx'
  else
    fail '_infer_pull_backend plain MLX model on arm64 → mlx' "expected 'mlx', got '$result'"
  fi
}

# ── search/list/remove/launch command helpers ──────────────────────────────

test_search_quants_jq_defs_extract_quants_and_default() {
  local jq_defs payload quants default_quant
  jq_defs="$(_search_quants_jq_defs)"
  payload='[{"siblings":[{"rfilename":"demo/model-Q4_K_M.gguf"},{"rfilename":"demo/model-Q8_0.gguf"},{"rfilename":"demo/readme.md"}]}]'

  quants="$(printf '%s' "$payload" | jq -r "${jq_defs}"'.[] | quants | join(",")')"
  default_quant="$(printf '%s' "$payload" | jq -r "${jq_defs}"'.[] | default_quant')"

  if assert_contains "$quants" 'Q4_K_M' && \
     assert_contains "$quants" 'Q8_0' && \
     assert_eq "$default_quant" 'Q4_K_M'; then
    pass 'search_quants_jq_defs extracts quants and default quant'
  else
    fail 'search_quants_jq_defs extracts quants and default quant' "unexpected quants='$quants' default='$default_quant'"
  fi
}

test_parse_search_args_with_query_and_flags() {
  if ! _parse_search_args --backend llama.cpp gemma --sort downloads --limit 5 --quants --quiet; then
    fail 'parse_search_args accepts query and flags' "unexpected parse error: ${REPLY_SEARCH_ERROR}"
    return
  fi

  if assert_eq "$REPLY_SEARCH_BACKEND_FLAG" 'llama.cpp' && \
     assert_eq "$REPLY_SEARCH_QUERY" 'gemma' && \
     assert_eq "$REPLY_SEARCH_SORT" 'downloads' && \
     assert_eq "$REPLY_SEARCH_LIMIT" '5' && \
     assert_eq "$REPLY_SEARCH_QUANTS" 'true' && \
     assert_eq "$REPLY_SEARCH_QUIET" 'true'; then
    pass 'parse_search_args accepts query and flags'
  else
    fail 'parse_search_args accepts query and flags' "unexpected parse result: backend='$REPLY_SEARCH_BACKEND_FLAG' query='$REPLY_SEARCH_QUERY' sort='$REPLY_SEARCH_SORT' limit='$REPLY_SEARCH_LIMIT' quants='$REPLY_SEARCH_QUANTS' quiet='$REPLY_SEARCH_QUIET'"
  fi
}

test_parse_search_args_rejects_extra_positional() {
  set +e
  _parse_search_args gemma qwen
  local status=$?
  set -e

  if [[ $status -ne 0 ]] && assert_contains "$REPLY_SEARCH_ERROR" 'Unknown argument: qwen'; then
    pass 'parse_search_args rejects extra positional arguments'
  else
    fail 'parse_search_args rejects extra positional arguments' "expected unknown argument error, got status=$status error='${REPLY_SEARCH_ERROR}'"
  fi
}

test_cmd_search_defaults_to_llama_backend() {
  local mock_bin="${TEST_ROOT}/mock-search-default"
  mkdir -p "$mock_bin"

  cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_LOG}"
printf '%s' '[{"modelId":"demo/gemma-GGUF","downloads":123}]'
EOF
  chmod +x "${mock_bin}/curl"

  local stdout_file="${TEST_ROOT}/stdout.search.default"
  local stderr_file="${TEST_ROOT}/stderr.search.default"
  local curl_log="${TEST_ROOT}/curl.search.default.log"
  : >"$curl_log"

  set +e
  CURL_LOG="$curl_log" PATH="${mock_bin}:$PATH" cmd_search gemma >"$stdout_file" 2>"$stderr_file"
  local status=$?
  set -e

  local out err
  out="$(cat "$stdout_file")"
  err="$(cat "$stderr_file")"

  if [[ $status -ne 0 ]]; then
    fail 'cmd_search defaults to llama backend' "search failed: $err"
    return
  fi

  if assert_contains "$out" 'llama.cpp' && \
     assert_contains "$(cat "$curl_log")" 'filter=gguf' && \
     ! assert_contains "$(cat "$curl_log")" 'filter=mlx'; then
    pass 'cmd_search defaults to llama backend'
  else
    fail 'cmd_search defaults to llama backend' "unexpected output='$out' curl='$(cat "$curl_log")'"
  fi
}

test_parse_list_args_tracks_scope_flags() {
  if ! _parse_list_args --backend mlx --quiet --models --templates; then
    fail 'parse_list_args handles backend quiet and scope flags' "unexpected parse error: ${REPLY_LIST_ERROR}"
    return
  fi

  if assert_eq "$REPLY_LIST_BACKEND_FLAG" 'mlx' && \
     assert_eq "$REPLY_LIST_QUIET" 'true' && \
     assert_eq "$REPLY_LIST_SHOW_MODELS" 'true' && \
     assert_eq "$REPLY_LIST_SHOW_PROFILES" 'false' && \
     assert_eq "$REPLY_LIST_SHOW_TEMPLATES" 'true'; then
    pass 'parse_list_args handles backend quiet and scope flags'
  else
    fail 'parse_list_args handles backend quiet and scope flags' "unexpected scope result: backend='$REPLY_LIST_BACKEND_FLAG' quiet='$REPLY_LIST_QUIET' models='$REPLY_LIST_SHOW_MODELS' profiles='$REPLY_LIST_SHOW_PROFILES' templates='$REPLY_LIST_SHOW_TEMPLATES'"
  fi
}

test_cmd_list_sorts_models_alphabetically() {
  local test_hub_dir="${TEST_ROOT}/hub-sort-models"
  mkdir -p "${test_hub_dir}/models--zorg--zmodel/snapshots/abc123"
  touch "${test_hub_dir}/models--zorg--zmodel/snapshots/abc123/model-Q4_K_M.gguf"
  mkdir -p "${test_hub_dir}/models--alpha--amodel/snapshots/abc123"
  touch "${test_hub_dir}/models--alpha--amodel/snapshots/abc123/model-Q4_K_M.gguf"
  mkdir -p "${test_hub_dir}/models--meta-llama--mmodel/snapshots/abc123"
  touch "${test_hub_dir}/models--meta-llama--mmodel/snapshots/abc123/model-Q4_K_M.gguf"

  local saved_HF_HUB_DIR="$HF_HUB_DIR"
  HF_HUB_DIR="$test_hub_dir"
  local result
  result="$(cmd_list --quiet --models --backend llama.cpp)"
  HF_HUB_DIR="$saved_HF_HUB_DIR"

  local before_meta="${result%%meta-llama*}"
  local before_zorg="${result%%zorg*}"
  if [[ "$before_meta" == *"alpha"* ]] && [[ "$before_zorg" == *"meta-llama"* ]]; then
    pass 'cmd_list --models outputs models sorted alphabetically'
  else
    fail 'cmd_list --models outputs models sorted alphabetically' "got: $result"
  fi
}

test_cmd_list_sorts_profiles_alphabetically() {
  local test_profiles_dir="${TEST_ROOT}/profiles-sort"
  mkdir -p "$test_profiles_dir"
  printf 'model=user/zorg\n' > "${test_profiles_dir}/zorg-profile"
  printf 'model=user/alpha\n' > "${test_profiles_dir}/alpha-profile"
  printf 'model=user/middle\n' > "${test_profiles_dir}/middle-profile"

  local saved_CORRAL_PROFILES_DIR="${CORRAL_PROFILES_DIR:-}"
  CORRAL_PROFILES_DIR="$test_profiles_dir"
  local result
  result="$(cmd_list --quiet --profiles)"
  CORRAL_PROFILES_DIR="$saved_CORRAL_PROFILES_DIR"

  local before_middle="${result%%middle-profile*}"
  local before_zorg="${result%%zorg-profile*}"
  if [[ "$before_middle" == *"alpha-profile"* ]] && [[ "$before_zorg" == *"middle-profile"* ]]; then
    pass 'cmd_list --profiles outputs profiles sorted alphabetically'
  else
    fail 'cmd_list --profiles outputs profiles sorted alphabetically' "got: $result"
  fi
}

test_cmd_list_sorts_templates_alphabetically() {
  local test_templates_dir="${TEST_ROOT}/templates-sort"
  mkdir -p "$test_templates_dir"
  printf '# user template\n' > "${test_templates_dir}/zeta-tmpl"
  printf '# user template\n' > "${test_templates_dir}/alpha-tmpl"

  local saved_CORRAL_TEMPLATES_DIR="${CORRAL_TEMPLATES_DIR:-}"
  CORRAL_TEMPLATES_DIR="$test_templates_dir"
  local result
  result="$(cmd_list --quiet --templates)"
  CORRAL_TEMPLATES_DIR="$saved_CORRAL_TEMPLATES_DIR"

  local before_zeta="${result%%zeta-tmpl*}"
  if [[ "$before_zeta" == *"alpha-tmpl"* ]]; then
    pass 'cmd_list --templates outputs templates sorted alphabetically'
  else
    fail 'cmd_list --templates outputs templates sorted alphabetically' "got: $result"
  fi
}

test_parse_remove_args_parses_backend_force_and_target() {
  if ! _parse_remove_args --backend mlx demo/model --force; then
    fail 'parse_remove_args accepts backend target and force' "unexpected parse error: ${REPLY_REMOVE_ERROR}"
    return
  fi

  if assert_eq "$REPLY_REMOVE_BACKEND_FLAG" 'mlx' && \
     assert_eq "$REPLY_REMOVE_TARGET_SPEC" 'demo/model' && \
     assert_eq "$REPLY_REMOVE_FORCE" 'true'; then
    pass 'parse_remove_args accepts backend target and force'
  else
    fail 'parse_remove_args accepts backend target and force' "unexpected parse result: backend='$REPLY_REMOVE_BACKEND_FLAG' target='$REPLY_REMOVE_TARGET_SPEC' force='$REPLY_REMOVE_FORCE'"
  fi
}

test_parse_launch_args_parses_port_tool_and_passthrough_args() {
  if ! _parse_launch_args --port 8082 pi -- --resume last; then
    fail 'parse_launch_args accepts port tool and passthrough args' "unexpected parse error: ${REPLY_LAUNCH_ERROR}"
    return
  fi

  if assert_eq "$REPLY_LAUNCH_REQUESTED_PORT" '8082' && \
     assert_eq "$REPLY_LAUNCH_TOOL" 'pi' && \
     assert_eq "${REPLY_LAUNCH_EXTRA_ARGS[*]}" '--resume last'; then
    pass 'parse_launch_args accepts port tool and passthrough args'
  else
    fail 'parse_launch_args accepts port tool and passthrough args' "unexpected parse result: port='$REPLY_LAUNCH_REQUESTED_PORT' tool='$REPLY_LAUNCH_TOOL' extra='${REPLY_LAUNCH_EXTRA_ARGS[*]}'"
  fi
}

test_parse_launch_args_rejects_invalid_port() {
  set +e
  _parse_launch_args --port abc pi
  local status=$?
  set -e

  if [[ $status -ne 0 ]] && assert_contains "$REPLY_LAUNCH_ERROR" "invalid port 'abc'"; then
    pass 'parse_launch_args rejects invalid port values'
  else
    fail 'parse_launch_args rejects invalid port values' "expected invalid port error, got status=$status error='${REPLY_LAUNCH_ERROR}'"
  fi
}

# ── run/serve command helpers ───────────────────────────────────────────────

test_parse_model_command_args_with_backend_and_extra_args() {
  if ! _parse_model_command_args --backend mlx assistant -- --seed 7; then
    fail 'parse_model_command_args accepts backend and passthrough args' "unexpected parse error: ${REPLY_MODEL_COMMAND_ERROR}"
    return
  fi

  if assert_eq "$REPLY_MODEL_COMMAND_BACKEND_FLAG" "mlx" && \
     assert_eq "$REPLY_MODEL_COMMAND_MODEL_SPEC" "assistant" && \
     assert_eq "${REPLY_MODEL_COMMAND_EXTRA_ARGS[*]}" "--seed 7"; then
    pass 'parse_model_command_args accepts backend and passthrough args'
  else
    fail 'parse_model_command_args accepts backend and passthrough args' "unexpected parse result: backend='$REPLY_MODEL_COMMAND_BACKEND_FLAG' model='$REPLY_MODEL_COMMAND_MODEL_SPEC' extra='${REPLY_MODEL_COMMAND_EXTRA_ARGS[*]}'"
  fi
}

test_parse_model_command_args_model_before_backend() {
  if ! _parse_model_command_args assistant --backend mlx; then
    fail 'parse_model_command_args accepts model before --backend' "unexpected parse error: ${REPLY_MODEL_COMMAND_ERROR}"
    return
  fi

  if assert_eq "$REPLY_MODEL_COMMAND_BACKEND_FLAG" "mlx" && \
     assert_eq "$REPLY_MODEL_COMMAND_MODEL_SPEC" "assistant"; then
    pass 'parse_model_command_args accepts model before --backend'
  else
    fail 'parse_model_command_args accepts model before --backend' "unexpected parse result: backend='$REPLY_MODEL_COMMAND_BACKEND_FLAG' model='$REPLY_MODEL_COMMAND_MODEL_SPEC'"
  fi
}

test_parse_model_command_args_model_before_backend_with_extra_args() {
  if ! _parse_model_command_args some/model --backend llama.cpp -- -ngl 999; then
    fail 'parse_model_command_args accepts model before --backend with extra args' "unexpected parse error: ${REPLY_MODEL_COMMAND_ERROR}"
    return
  fi

  if assert_eq "$REPLY_MODEL_COMMAND_BACKEND_FLAG" "llama.cpp" && \
     assert_eq "$REPLY_MODEL_COMMAND_MODEL_SPEC" "some/model" && \
     assert_eq "${REPLY_MODEL_COMMAND_EXTRA_ARGS[*]}" "-ngl 999"; then
    pass 'parse_model_command_args accepts model before --backend with extra args'
  else
    fail 'parse_model_command_args accepts model before --backend with extra args' "unexpected: backend='$REPLY_MODEL_COMMAND_BACKEND_FLAG' model='$REPLY_MODEL_COMMAND_MODEL_SPEC' extra='${REPLY_MODEL_COMMAND_EXTRA_ARGS[*]}'"
  fi
}

test_parse_model_command_args_rejects_unknown_argument() {
  set +e
  _parse_model_command_args assistant --seed
  local status=$?
  set -e

  if [[ $status -ne 0 ]] && assert_contains "$REPLY_MODEL_COMMAND_ERROR" "Unknown argument: --seed"; then
    pass 'parse_model_command_args rejects missing separator before passthrough args'
  else
    fail 'parse_model_command_args rejects missing separator before passthrough args' "expected unknown argument error, got status=$status error='${REPLY_MODEL_COMMAND_ERROR}'"
  fi
}

test_parse_model_command_args_rejects_missing_backend_value() {
  set +e
  _parse_model_command_args assistant --backend
  local status=$?
  set -e

  if [[ $status -ne 0 ]] && assert_contains "$REPLY_MODEL_COMMAND_ERROR" "missing value for --backend"; then
    pass 'parse_model_command_args rejects missing backend value'
  else
    fail 'parse_model_command_args rejects missing backend value' "expected missing backend value error, got status=$status error='${REPLY_MODEL_COMMAND_ERROR}'"
  fi
}

test_resolve_model_command_context_filters_profile_for_llama_backend() {
  _create_unit_profile_fixture "coder-llama" "$(cat <<'EOF'
model=unsloth/gemma-4-27b-it-GGUF:Q4_K_M
--temp 0.2
[run]
--top-k 40
[mlx]
--mlx-only 1
[llama.cpp]
--ctx-size 8192
[llama.cpp.run]
-ngl 999
EOF
)"

  _resolve_model_command_context run "" "coder-llama"
  local args_string="${REPLY_MODEL_COMMAND_PROFILE_ARGS[*]}"

  if assert_eq "$REPLY_MODEL_COMMAND_BACKEND" "llama.cpp" && \
     assert_eq "$REPLY_MODEL_COMMAND_MODEL_SPEC" "unsloth/gemma-4-27b-it-GGUF:Q4_K_M" && \
     assert_contains "$args_string" "--temp 0.2" && \
     assert_contains "$args_string" "--top-k 40" && \
     assert_contains "$args_string" "--ctx-size 8192" && \
     assert_contains "$args_string" "-ngl 999" && \
     ! assert_contains "$args_string" "--mlx-only" 2>/dev/null; then
    pass 'resolve_model_command_context loads llama.cpp-scoped profile args'
  else
    fail 'resolve_model_command_context loads llama.cpp-scoped profile args' "unexpected backend='$REPLY_MODEL_COMMAND_BACKEND' model='$REPLY_MODEL_COMMAND_MODEL_SPEC' args='$args_string'"
  fi
}

test_resolve_model_command_context_filters_profile_for_explicit_mlx_backend() {
  _create_unit_profile_fixture "coder-mlx" "$(cat <<'EOF'
model=mlx-community/Qwen3-8B-4bit
--temp 0.2
[run]
--top-k 40
[mlx]
--max-kv-size 4096
[mlx.run]
--seed 7
[llama.cpp]
-ngl 999
EOF
)"

  _resolve_model_command_context run "mlx" "coder-mlx"
  local args_string="${REPLY_MODEL_COMMAND_PROFILE_ARGS[*]}"

  if assert_eq "$REPLY_MODEL_COMMAND_BACKEND" "mlx" && \
     assert_eq "$REPLY_MODEL_COMMAND_MODEL_SPEC" "mlx-community/Qwen3-8B-4bit" && \
     assert_contains "$args_string" "--temp 0.2" && \
     assert_contains "$args_string" "--top-k 40" && \
     assert_contains "$args_string" "--max-kv-size 4096" && \
     assert_contains "$args_string" "--seed 7" && \
     ! assert_contains "$args_string" "-ngl 999" 2>/dev/null; then
    pass 'resolve_model_command_context loads explicit mlx-scoped profile args'
  else
    fail 'resolve_model_command_context loads explicit mlx-scoped profile args' "unexpected backend='$REPLY_MODEL_COMMAND_BACKEND' model='$REPLY_MODEL_COMMAND_MODEL_SPEC' args='$args_string'"
  fi
}

test_load_profile_strips_trailing_spaces_and_tabs() {
  _create_unit_profile_fixture "trailing-whitespace" $'model=mlx-community/Qwen3-8B-4bit   \n--temp 0.2\t\n[mlx]\t\n--max-tokens 128  '

  load_profile "trailing-whitespace" run mlx
  local args_string="${REPLY_PROFILE_ARGS[*]}"

  if assert_eq "$REPLY_PROFILE_MODEL" "mlx-community/Qwen3-8B-4bit" && \
     assert_eq "$args_string" "--temp 0.2 --max-tokens 128"; then
    pass 'load_profile strips trailing spaces and tabs'
  else
    fail 'load_profile strips trailing spaces and tabs' "unexpected model='$REPLY_PROFILE_MODEL' args='$args_string'"
  fi
}

test_load_profile_supports_indented_and_trailing_comments() {
  _create_unit_profile_fixture "commented-profile" $'   # leading comment\n   model=mlx-community/Qwen3-8B-4bit   # model comment\n   --temp 0.2   # flag comment\n   [mlx]\n      # section comment\n   --max-tokens 128   # trailing comment'

  load_profile "commented-profile" run mlx
  local args_string="${REPLY_PROFILE_ARGS[*]}"

  if assert_eq "$REPLY_PROFILE_MODEL" "mlx-community/Qwen3-8B-4bit" && \
     assert_eq "$args_string" "--temp 0.2 --max-tokens 128"; then
    pass 'load_profile supports indented and trailing comments'
  else
    fail 'load_profile supports indented and trailing comments' "unexpected model='$REPLY_PROFILE_MODEL' args='$args_string'"
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
  if assert_contains "$result" 'gemma|built-in|unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL' && \
     assert_contains "$result" 'glimmer|built-in|meta-models/Muse-Glimmer-30B-GGUF:Q4_K_M' && \
     assert_contains "$result" 'qwen|built-in|unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL'; then
    pass 'collect_template_entries includes built-ins with default models'
  else
    fail 'collect_template_entries includes built-ins with default models' "got: $result"
  fi
}

test_collect_template_entries_reads_only_templates_dir() {
  local templates_dir="${TEST_ROOT}/templates-primary"
  local profiles_dir="${TEST_ROOT}/profiles-dir"
  mkdir -p "$templates_dir" "$profiles_dir/templates"
  printf 'model=demo/current:Q4_K\n' > "${templates_dir}/current-tmpl"
  printf 'model=demo/ignored:Q4_K\n' > "${profiles_dir}/templates/ignored-tmpl"

  local saved_CORRAL_TEMPLATES_DIR="${CORRAL_TEMPLATES_DIR:-}"
  local saved_CORRAL_PROFILES_DIR="${CORRAL_PROFILES_DIR:-}"
  CORRAL_TEMPLATES_DIR="$templates_dir"
  CORRAL_PROFILES_DIR="$profiles_dir"

  local result
  result="$(collect_template_entries)"

  CORRAL_TEMPLATES_DIR="$saved_CORRAL_TEMPLATES_DIR"
  CORRAL_PROFILES_DIR="$saved_CORRAL_PROFILES_DIR"

  if assert_contains "$result" 'current-tmpl|user|demo/current:Q4_K' && \
     ! assert_contains "$result" 'ignored-tmpl|user|demo/ignored:Q4_K'; then
    pass 'collect_template_entries reads only templates dir'
  else
    fail 'collect_template_entries reads only templates dir' "got: $result"
  fi
}

test_collect_template_entries_includes_model_less_user_templates() {
  local templates_dir="${TEST_ROOT}/templates-model-less"
  mkdir -p "$templates_dir"
  printf '%s\n' '--temp 0.3' > "${templates_dir}/custom2"

  local saved_CORRAL_TEMPLATES_DIR="${CORRAL_TEMPLATES_DIR:-}"
  CORRAL_TEMPLATES_DIR="$templates_dir"

  local result
  result="$(collect_template_entries)"

  CORRAL_TEMPLATES_DIR="$saved_CORRAL_TEMPLATES_DIR"

  if assert_contains "$result" 'custom2|user|(none)'; then
    pass 'collect_template_entries includes user templates without model lines'
  else
    fail 'collect_template_entries includes user templates without model lines' "got: $result"
  fi
}

# ── completions_fish ─────────────────────────────────────────────────────────

test_completions_fish_generation() {
  local out
  out="$(completions_fish)"

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
  out="$(completions_fish)"

  if ! assert_contains "$out" 'complete -c corral -n "__corral_profile_needs_target" -a "(__corral_templates) (__corral_cached_models)"'; then
    fail '_completions_fish completes profile target from templates and models' 'expected profile target completion line in generated fish script'
    return
  fi

  if ! assert_contains "$out" 'complete -c corral -n "__corral_profile_needs_model" -a "(__corral_cached_models)"'; then
    fail '_completions_fish completes profile model after template' 'expected profile model completion line in generated fish script'
    return
  fi

  pass '_completions_fish completes profile template/model positionals'
}

test_completions_include_copy_and_template_removal_targets() {
  local fish_out zsh_out bash_out
  fish_out="$(completions_fish)"
  zsh_out="$(completions_zsh)"
  bash_out="$(completions_bash)"

  if assert_contains "$fish_out" 'complete -c corral -n "__fish_seen_subcommand_from copy cp"      -a "(__corral_copy_sources)"' && \
     assert_contains "$fish_out" 'function __corral_copy_sources' && \
     assert_contains "$fish_out" 'function __corral_removal_targets' && \
     assert_contains "$fish_out" '__corral_templates'; then
    pass '_completions_fish includes copy aliases and template removal targets'
  else
    fail '_completions_fish includes copy aliases and template removal targets' "got: $fish_out"
  fi

  if assert_contains "$zsh_out" "'copy:Copy a profile or template'" && \
     assert_contains "$zsh_out" "'cp:Copy a profile or template'" && \
     assert_contains "$zsh_out" "'templates:template:_corral_templates'" && \
     assert_contains "$zsh_out" "'profile:Create or replace a named profile'"; then
    pass '_completions_zsh includes copy aliases and template removal targets'
  else
    fail '_completions_zsh includes copy aliases and template removal targets' "got: $zsh_out"
  fi

  if assert_contains "$bash_out" 'copy|cp)' && \
     assert_contains "$bash_out" 'COMPREPLY=($(compgen -W "$profiles_words $templates_words" -- "$cur"))' && \
     assert_contains "$bash_out" 'removables_words="${models_words} ${profiles_words} ${templates_words}"'; then
    pass '_completions_bash includes copy aliases and template removal targets'
  else
    fail '_completions_bash includes copy aliases and template removal targets' "got: $bash_out"
  fi
}

test_completions_zsh_profile_template_filtering() {
  local out
  out="$(completions_zsh)"

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
  out="$(completions_zsh)"

  if ! assert_contains "$out" "_alternative 'templates:template:_corral_templates' 'models:model:_corral_cached_models'"; then
    fail '_completions_zsh completes profile target from templates and models' 'expected zsh profile target completion alternative'
    return
  fi

  if ! assert_contains "$out" "if _corral_has_template \"\$words[3]\"; then"; then
    fail '_completions_zsh completes profile model after template' 'expected zsh template-aware model completion block'
    return
  fi

  pass '_completions_zsh completes profile template/model positionals'
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
  out="$(completions_bash)"

  if ! assert_contains "$out" "elif [[ \$COMP_CWORD -eq 3 ]]; then"; then
    fail '_completions_bash completes profile target from templates and models' 'expected bash target position branch for profile'
    return
  fi

  if ! assert_contains "$out" "COMPREPLY=(\$(compgen -W \"\$templates_words \$models_words\" -- \"\$cur\"))"; then
    fail '_completions_bash completes profile target from templates and models' 'expected bash target completion list for profile'
    return
  fi

  if ! assert_contains "$out" "if [[ \$target_is_template -eq 1 ]]; then"; then
    fail '_completions_bash completes profile model after template' 'expected bash template-aware model completion block'
    return
  fi

  pass '_completions_bash completes profile template/model positionals'
}

run_selected_tests() {
  local test_name

  for test_name in "$@"; do
    if ! declare -F "$test_name" >/dev/null 2>&1; then
      echo "Unknown test: $test_name" >&2
      exit 1
    fi
    "$test_name"
  done
}

# ── launch helpers ───────────────────────────────────────────────────────────

test_render_merged_json_file_preserves_unrelated_keys() {
  local path rendered
  path="${TEST_ROOT}/launch-settings.json"
  cat >"$path" <<'EOF'
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

  rendered="$(_render_merged_json_file "$path" '{"defaultProvider":"corral-launch","defaultModel":"demo/server-model"}')"

  if assert_contains "$rendered" '"packages"' && \
     assert_contains "$rendered" '"defaultProvider": "corral-launch"' && \
     assert_contains "$rendered" '"defaultModel": "demo/server-model"'; then
    pass 'render merged json preserves unrelated keys'
  else
    fail 'render merged json preserves unrelated keys' "unexpected merged json: $rendered"
  fi
}

test_render_merged_json_file_accepts_jsonc() {
  local path rendered
  path="${TEST_ROOT}/launch-opencode.jsonc"
  cat >"$path" <<'EOF'
{
  // existing config
  "provider": {
    "existing": {
      "npm": "example",
    },
  },
}
EOF

  rendered="$(_render_merged_json_file "$path" '{"model":"corral-launch/demo"}' 1)"

  if assert_contains "$rendered" '"existing"' && \
     assert_contains "$rendered" '"model": "corral-launch/demo"'; then
    pass 'render merged json accepts jsonc'
  else
    fail 'render merged json accepts jsonc' "unexpected merged jsonc output: $rendered"
  fi
}

test_render_merged_json_file_migrates_pi_models_schema() {
  local path rendered
  path="${TEST_ROOT}/launch-pi-models.json"
  cat >"$path" <<'EOF'
{
  "existing": {
    "baseUrl": "https://example.invalid/v1",
    "api": "openai-completions",
    "models": [
      "example/model"
    ]
  }
}
EOF

  rendered="$(_render_merged_json_file "$path" '{"providers":{"corral-launch":{"baseUrl":"http://127.0.0.1:8080/v1","api":"openai-completions","models":[{"id":"demo/server-model"}]}}}' 0 "pi-models")"

  if assert_contains "$rendered" '"providers"' && \
     assert_contains "$rendered" '"existing"' && \
     assert_contains "$rendered" '"corral-launch"' && \
     assert_contains "$rendered" '"id": "demo/server-model"'; then
    pass 'render merged json migrates pi models schema'
  else
    fail 'render merged json migrates pi models schema' "unexpected migrated pi models json: $rendered"
  fi
}

test_render_code_models_file_replaces_corral_provider() {
  local path rendered
  path="${TEST_ROOT}/chatLanguageModels.json"
  cat >"$path" <<'EOF'
[
  {
    "name": "Copilot",
    "vendor": "copilot"
  },
  {
    "name": "Corral",
    "vendor": "customendpoint",
    "models": [
      {
        "id": "old/model"
      }
    ]
  }
]
EOF

  rendered="$(_render_code_models_file "$path" '{"name":"Corral","vendor":"customendpoint","apiType":"chat-completions","models":[{"id":"demo/server-model"}]}')"

  if assert_eq "$(printf '%s\n' "$rendered" | jq 'length')" '2' && \
     assert_eq "$(printf '%s\n' "$rendered" | jq -r '.[0].name')" 'Copilot' && \
     assert_eq "$(printf '%s\n' "$rendered" | jq -r '.[1].models[0].id')" 'demo/server-model'; then
    pass 'render code models file replaces Corral provider'
  else
    fail 'render code models file replaces Corral provider' "unexpected merged providers: $rendered"
  fi
}

test_set_copilot_token_limits_uses_context_percentages_and_fallback() {
  _set_copilot_token_limits 131072
  if ! assert_eq "$REPLY_LAUNCH_MAX_INPUT_TOKENS" '98304' || \
     ! assert_eq "$REPLY_LAUNCH_MAX_OUTPUT_TOKENS" '16384'; then
    fail 'copilot token limits use context percentages and fallback' "unexpected limits for 131072: input=${REPLY_LAUNCH_MAX_INPUT_TOKENS} output=${REPLY_LAUNCH_MAX_OUTPUT_TOKENS}"
    return
  fi

  _set_copilot_token_limits ""
  if assert_eq "$REPLY_LAUNCH_MAX_INPUT_TOKENS" '49152' && \
     assert_eq "$REPLY_LAUNCH_MAX_OUTPUT_TOKENS" '8192'; then
    pass 'copilot token limits use context percentages and fallback'
  else
    fail 'copilot token limits use context percentages and fallback' "unexpected fallback limits: input=${REPLY_LAUNCH_MAX_INPUT_TOKENS} output=${REPLY_LAUNCH_MAX_OUTPUT_TOKENS}"
  fi
}

test_code_models_config_path_uses_platform_user_dir() {
  local original_xdg="${XDG_CONFIG_HOME-}"
  local mac_path linux_path

  uname() {
    printf 'Darwin\n'
  }
  mac_path="$(_code_models_config_path)"

  uname() {
    printf 'Linux\n'
  }
  XDG_CONFIG_HOME="${TEST_ROOT}/xdg"
  linux_path="$(_code_models_config_path)"

  unset -f uname
  if [[ -n "$original_xdg" ]]; then
    XDG_CONFIG_HOME="$original_xdg"
  else
    unset XDG_CONFIG_HOME
  fi

  if assert_eq "$mac_path" "$HOME/Library/Application Support/Code/User/chatLanguageModels.json" && \
     assert_eq "$linux_path" "${TEST_ROOT}/xdg/Code/User/chatLanguageModels.json"; then
    pass 'code models config path uses platform user directory'
  else
    fail 'code models config path uses platform user directory' "unexpected paths: mac='$mac_path' linux='$linux_path'"
  fi
}

test_launch_tool_supports_process_matrix() {
  if _launch_tool_supports_process pi mlx_lm.server && \
     _launch_tool_supports_process opencode llama-server && \
     _launch_tool_supports_process copilot llama-server && \
     _launch_tool_supports_process codex llama-server && \
     _launch_tool_supports_process code llama-server && \
     ! _launch_tool_supports_process copilot mlx_lm.server && \
     ! _launch_tool_supports_process codex mlx_lm.server && \
     ! _launch_tool_supports_process code mlx_lm.server && \
     ! _launch_tool_supports_process pi llama-cli; then
    pass 'launch tool support matrix'
  else
    fail 'launch tool support matrix' 'unexpected server compatibility result'
  fi
}

test_toml_string_literal_escapes_values() {
  local rendered
  rendered="$(_toml_string_literal 'demo/"quoted"\model')"

  if assert_eq "$rendered" '"demo/\"quoted\"\\model"'; then
    pass 'toml string literal escapes values'
  else
    fail 'toml string literal escapes values' "unexpected TOML string: $rendered"
  fi
}

test_write_codex_model_catalog_uses_freeform_tools_metadata() {
  local catalog shell_type apply_patch_tool search_enabled context_window

  _write_codex_model_catalog 'unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M' 32768
  catalog="$REPLY_CODEX_MODEL_CATALOG"

  shell_type="$(jq -r '.models[0].shell_type' "$catalog")"
  apply_patch_tool="$(jq -r '.models[0].apply_patch_tool_type' "$catalog")"
  search_enabled="$(jq -r '.models[0].supports_search_tool' "$catalog")"
  context_window="$(jq -r '.models[0].context_window' "$catalog")"

  if assert_eq "$shell_type" 'local' && \
     assert_eq "$apply_patch_tool" 'freeform' && \
     assert_eq "$search_enabled" 'false' && \
     assert_eq "$context_window" '32768'; then
    pass 'write codex model catalog uses codex-compatible metadata'
  else
    fail 'write codex model catalog uses codex-compatible metadata' "unexpected catalog: $(cat "$catalog")"
  fi
}

test_completions_include_launch() {
  local fish_out zsh_out bash_out
  fish_out="$(completions_fish)"
  zsh_out="$(completions_zsh)"
  bash_out="$(completions_bash)"

  if assert_contains "$fish_out" 'launch' && \
     assert_contains "$fish_out" 'pi opencode codex copilot code' && \
     assert_contains "$zsh_out" 'launch:Configure and launch a supported coding harness' && \
     assert_contains "$bash_out" 'pi opencode codex copilot code'; then
    pass 'completions include launch'
  else
    fail 'completions include launch' 'expected launch command and tool completions in generated shells'
  fi
}

# ── run tests ────────────────────────────────────────────────────────────────

if [[ $# -gt 0 ]]; then
  run_selected_tests "$@"
else
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
  test_find_cached_gguf_files_ignores_mmproj_sidecars
  test_find_cached_gguf_files_ignores_suffix_mmproj_sidecars
  test_find_cached_gguf_files_ignores_mtp_sidecars
  test_find_gguf_by_quant_match
  test_find_gguf_by_quant_case_insensitive
  test_cached_quant_tags
  test_cached_quant_tags_empty
  test_cache_has_model_dir_exists
  test_cache_has_model_dir_missing
  test_cache_has_quant_match
  test_cache_has_quant_no_match
  test_collect_cached_model_entries
  test_collect_cached_model_entries_deduplicates_shared_snapshot_blobs
  test_collect_mlx_model_entries_includes_safetensors_cache
  test_collect_mlx_model_entries_ignores_gguf_cache
  test_collect_mlx_model_entries_ignores_no_weights_cache
  test_infer_remove_backend_quant_suffix
  test_infer_remove_backend_cached_gguf_on_arm64
  test_infer_remove_backend_cached_mlx_on_arm64
  test_infer_remove_backend_rejects_mixed_cache
  test_validate_profile_name_valid
  test_validate_profile_name_invalid
  test_validate_profile_name_empty
  test_validate_template_name_valid
  test_validate_template_name_invalid
  test_builtin_template_gemma
  test_builtin_template_qwen
  test_builtin_template_glimmer
  test_builtin_template_unknown
  test_detect_arch
  test_platform_default_backend_macos_arm64
  test_platform_default_backend_non_macos_arm64
  test_resolve_backend_prefers_flag
  test_resolve_backend_falls_back_to_platform_default
  test_resolve_backend_rejects_invalid_value
  test_normalize_dir_path_expands_tilde_and_strips_trailing_slash
  test_normalize_dir_path_preserves_root
  test_print_tsv_table_dynamic_widths
  test_print_tsv_table_ignores_ansi_width
  test_ansi_color_returns_named_escape_sequence
  test_wrap_color_applies_named_escape_sequence
  test_wrap_stdout_color_is_plain_without_tty
  test_stdout_supports_color_disabled_without_tty
  test_stdout_supports_color_disabled_by_no_color
  test_stdout_supports_color_disabled_for_dumb_term
  test_is_mlx_platform_arm64
  test_is_mlx_platform_non_arm64
  test_infer_model_backend_cached_gguf
  test_infer_model_backend_cached_mlx
  test_infer_model_backend_cached_mlx_on_linux
  test_infer_model_backend_uncached_arm64
  test_infer_model_backend_uncached_linux
  test_infer_pull_backend_gguf_suffix
  test_infer_pull_backend_quant_specifier
  test_infer_pull_backend_remote_gguf_metadata
  test_infer_pull_backend_mlx_model_arm64
  test_search_quants_jq_defs_extract_quants_and_default
  test_parse_search_args_with_query_and_flags
  test_parse_search_args_rejects_extra_positional
  test_cmd_search_defaults_to_llama_backend
  test_parse_list_args_tracks_scope_flags
  test_cmd_list_sorts_models_alphabetically
  test_cmd_list_sorts_profiles_alphabetically
  test_cmd_list_sorts_templates_alphabetically
  test_parse_remove_args_parses_backend_force_and_target
  test_parse_launch_args_parses_port_tool_and_passthrough_args
  test_parse_launch_args_rejects_invalid_port
  test_parse_model_command_args_with_backend_and_extra_args
  test_parse_model_command_args_model_before_backend
  test_parse_model_command_args_model_before_backend_with_extra_args
  test_parse_model_command_args_rejects_unknown_argument
  test_parse_model_command_args_rejects_missing_backend_value
  test_resolve_model_command_context_filters_profile_for_llama_backend
  test_resolve_model_command_context_filters_profile_for_explicit_mlx_backend
  test_load_profile_strips_trailing_spaces_and_tabs
  test_section_matches_common_always
  test_section_matches_command_sections
  test_section_matches_backend_sections
  test_section_matches_compound_sections
  test_collect_template_entries_includes_builtins
  test_collect_template_entries_reads_only_templates_dir
  test_collect_template_entries_includes_model_less_user_templates
  test_render_merged_json_file_preserves_unrelated_keys
  test_render_merged_json_file_accepts_jsonc
  test_render_merged_json_file_migrates_pi_models_schema
  test_render_code_models_file_replaces_corral_provider
  test_set_copilot_token_limits_uses_context_percentages_and_fallback
  test_code_models_config_path_uses_platform_user_dir
  test_launch_tool_supports_process_matrix
  test_toml_string_literal_escapes_values
  test_write_codex_model_catalog_uses_freeform_tools_metadata
  test_completions_fish_generation
  test_completions_fish_profile_set_positionals
  test_completions_include_copy_and_template_removal_targets
  test_completions_include_launch
  test_completions_zsh_profile_template_filtering
  test_completions_zsh_profile_set_positionals
  test_completions_bash_profile_template_filtering
  test_completions_bash_profile_set_positionals
fi

report_results
