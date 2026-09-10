# Cache and quant helpers for corral.
#
# Manages the local HuggingFace hub cache (~/.cache/huggingface/hub). Provides:
#   - Public helpers: parse_model_spec(), cache_dir_has_gguf(),
#     cache_dir_has_mlx_weights(), collect_cached_model_entries(),
#     collect_mlx_model_entries(), find_cached_gguf_files(), find_cached_gguf_paths(),
#     find_cached_gguf_paths_by_quant(), find_gguf_by_quant(), remove_quant_files(),
#     resolve_link(), model_name_to_cache_dir(), cache_dir_to_model_name()
#   - Quant extraction: extract_quant_from_filename(), normalize_quant_tag()
#   - GGUF discovery: _find_cached_gguf_paths() plus public lookup helpers
#   - MLX detection: cache_dir_has_mlx_weights() — positive match via safetensors/bin/pt
#   - Cache dir conversion: model_name_to_cache_dir() ↔ cache_dir_to_model_name()
#   - Entry collection: collect_cached_model_entries() (GGUF), collect_mlx_model_entries()
#   - Private cache helpers: _cached_quant_tags(), _find_cached_gguf_paths(),
#     _is_auxiliary_gguf_filename(), _is_mtp_sidecar_gguf_filename()
#
# Entry format: pipe-delimited "name|quant|size|backend" rows consumed by inventory commands.
# shellcheck shell=bash

# Parse "user/model[:quant]" into globals REPLY_MODEL and REPLY_QUANT.
# Uses bash parameter expansion operators:
#   %%:*  — remove the longest suffix matching ":*"  → everything before the first ':'
#   #*:   — remove the shortest prefix matching "*:" → everything after the first ':'
parse_model_spec() {
  local spec="$1"
  # shellcheck disable=SC2034  # Returned via REPLY_* globals consumed across modules.
  REPLY_MODEL="${spec%%:*}"
  if [[ "$spec" == *:* ]]; then
    # shellcheck disable=SC2034  # Returned via REPLY_* globals consumed across modules.
    REPLY_QUANT="${spec#*:}"
  else
    # shellcheck disable=SC2034  # Returned via REPLY_* globals consumed across modules.
    REPLY_QUANT=""
  fi
}

# Extract a quant tag from a GGUF filename for display and matching.
# e.g., "gemma-4-26B-A4B-it-UD-Q6_K.gguf" -> "UD-Q6_K"
# Falls back to the full basename (minus .gguf) if no known pattern matches.
#
# Regex anatomy for [-._](([A-Z][A-Z][-_])?(I?Q[0-9]+(_[A-Z0-9]+)*|F16|BF16|F32))$:
#   [-._]              separator character before the quant tag (.gguf naming uses all three)
#   (                  outer capture group — BASH_REMATCH[1] is the quant tag itself
#     ([A-Z][A-Z][-_])? optional two-letter vendor prefix, e.g. "UD-" or "IQ-"
#     (                inner capture group: the quantisation type
#       I?Q[0-9]+      optional 'I' then Q + digits (e.g. Q4, IQ3, Q6)
#       (_[A-Z0-9]+)*  zero or more underscore-separated suffixes (e.g. _K_M, _K_S, _0)
#       |F16|BF16|F32  float-precision alternatives
#     )
#   )$                 must be at end of the stem (after shard suffix is stripped)
extract_quant_from_filename() {
  local filename="$1"
  local base="${filename%.gguf}"
  # Strip shard suffix like "-00001-of-00003" from multi-file models.
  base="${base%-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]}"
  if [[ "$base" =~ [-._](([A-Z][A-Z][-_])?(I?Q[0-9]+(_[A-Z0-9]+)*|F16|BF16|F32))$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$base"
  fi
}

# Normalize quant tags for robust matching.
# - Case-insensitive by uppercasing.
# - Treat '-' and '_' as equivalent by converting '-' to '_'.
normalize_quant_tag() {
  local quant="$1"
  quant="$(printf '%s' "$quant" | tr '[:lower:]' '[:upper:]')"
  quant="${quant//-/_}"
  printf '%s\n' "$quant"
}

# Find cached model GGUF file paths in a model's HF cache snapshots directory.
# Auxiliary projector GGUFs with an `mmproj` stem token are intentionally
# excluded; they are sidecar files for multimodal models, not independently
# runnable quant variants.
# Prints one full path per line, deduplicated and sorted.
find_cached_gguf_paths() {
  local cache_dir="$1"
  _find_cached_gguf_paths "$cache_dir"
}

# Find cached model GGUF files in a model's HF cache snapshots directory.
# Prints one basename per line, deduplicated and sorted.
# 'while IFS= read -r': read one line at a time with no field-splitting (IFS=)
# and no backslash interpretation (-r). This is the safe idiom for processing
# lines that may contain spaces or special characters.
find_cached_gguf_files() {
  local cache_dir="$1"
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    basename "$f"
  done < <(find_cached_gguf_paths "$cache_dir") | sort -u
}

# Find cached GGUF filenames whose extracted quant tag matches the given tag.
# Prints matching basenames, one per line.
find_gguf_by_quant() {
  local cache_dir="$1"
  local quant="$2"
  local normalized_quant
  local fname
  normalized_quant="$(normalize_quant_tag "$quant")"
  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    local tag
    tag="$(extract_quant_from_filename "$fname")"
    if [[ "$(normalize_quant_tag "$tag")" == "$normalized_quant" ]]; then
      printf '%s\n' "$fname"
    fi
  done < <(find_cached_gguf_files "$cache_dir")
}

# Find cached GGUF file paths whose extracted quant tag matches the given tag.
# Prints matching full paths, one per line.
find_cached_gguf_paths_by_quant() {
  local cache_dir="$1"
  local quant="$2"
  local normalized_quant
  local path
  normalized_quant="$(normalize_quant_tag "$quant")"
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    local tag
    tag="$(extract_quant_from_filename "$(basename "$path")")"
    if [[ "$(normalize_quant_tag "$tag")" == "$normalized_quant" ]]; then
      printf '%s\n' "$path"
    fi
  done < <(find_cached_gguf_paths "$cache_dir")
}

# Resolve a symlink to its absolute target path using a subshell cd, avoiding
# a hard dependency on realpath (not available on all systems).
# The (cd ... && printf) runs in a subshell so the working directory change
# doesn't leak into the caller. $PWD after cd gives the canonical absolute path.
resolve_link() {
  local path="$1"
  if [[ -L "$path" ]]; then
    local dir target
    dir="$(dirname "$path")"
    target="$(readlink "$path")"
    # If the symlink target is relative, resolve it against the link's directory.
    if [[ "$target" != /* ]]; then
      target="${dir}/${target}"
    fi
    # Subshell cd: resolves '..' components and yields a clean absolute path.
    (cd "$(dirname "$target")" 2>/dev/null && printf '%s/%s' "$PWD" "$(basename "$target")")
  else
    printf '%s' "$path"
  fi
}

# Remove GGUF files matching a quant tag from the HF cache.
# HuggingFace stores actual file data as content-addressed "blob" files under
# blobs/ and creates symlinks in snapshots/ pointing to them. We must delete
# both the symlink in snapshots/ AND the backing blob to free disk space;
# deleting only the symlink leaves orphaned blobs behind.
# Returns 0 if at least one file was removed, 1 otherwise.
remove_quant_files() {
  local cache_dir="$1"
  local quant="$2"
  local removed=0
  local f
  # 'while ... done < <(cmd)': process substitution feeds cmd's stdout line
  # by line into the while loop. Unlike 'cmd | while', this keeps the loop
  # in the current shell so variable changes (e.g. removed++) persist.
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # If the file is a symlink, also delete the backing blob it points to.
    if [[ -L "$f" ]]; then
      local blob_path
      blob_path="$(resolve_link "$f")"
      if [[ -f "$blob_path" ]]; then
        rm -f "$blob_path"
      fi
    fi
    rm -f "$f"
    removed=$((removed + 1))
  done < <(find_cached_gguf_paths_by_quant "$cache_dir" "$quant")
  # Bash arithmetic: [[ expr ]] treats the result as a boolean test.
  [[ $removed -gt 0 ]]
}

# Convert "USER/MODEL" -> "${HF_HUB_DIR}/models--USER--MODEL".
# HuggingFace hub uses this directory-naming convention internally: forward
# slashes in the repo id are replaced with '--' to keep them as valid paths.
model_name_to_cache_dir() {
  local model_name="$1"
  local user="${model_name%%/*}"
  local model="${model_name#*/}"
  if [[ -z "$user" || -z "$model" || "$model" == */* ]]; then
    die "invalid model name '${model_name}': expected format USER/MODEL"
  fi
  printf '%s/models--%s--%s' "$HF_HUB_DIR" "$user" "$model"
}

# Reverse of model_name_to_cache_dir: extract "USER/MODEL" from a cache path.
# ${entry#models--}: strip the 'models--' prefix.
# ${entry/--//}:     replace the first '--' with '/' to restore the slash.
cache_dir_to_model_name() {
  local cache_dir="$1"
  local entry
  entry="$(basename "$cache_dir")"
  entry="${entry#models--}"
  printf '%s\n' "${entry/--//}"
}

collect_mlx_model_entries() {
  # MLX model visibility is derived from HF cache only; Corral keeps no
  # sidecar registry. Match runtime backend inference: any cached HF repo
  # with safetensors/bin/pt model weights is treated as an MLX model.
  if [[ -d "$HF_HUB_DIR" ]]; then
    local dir
    for dir in "$HF_HUB_DIR"/models--*/; do
      [[ -d "$dir" ]] || continue
      if ! cache_dir_has_mlx_weights "$dir"; then
        continue
      fi
      local model_name
      model_name="$(cache_dir_to_model_name "$dir")"
      local size
      size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
      printf '%s||%s|mlx\n' "$model_name" "$size"
    done
  fi
}

# Return success if a model cache directory contains MLX-compatible model
# weights (safetensors, .bin, or .pt). This positively identifies MLX models
# rather than inferring from absence of GGUF files.
cache_dir_has_mlx_weights() {
  local cache_dir="$1"
  local snapshot_dir
  for snapshot_dir in "$cache_dir"/snapshots/*/; do
    [[ -d "$snapshot_dir" ]] || continue
    if find "$snapshot_dir" \( -name '*.safetensors' -o -name '*.bin' -o -name '*.pt' \) -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

# Return success if a model cache directory contains at least one GGUF file.
cache_dir_has_gguf() {
  local cache_dir="$1"
  local gguf_files
  gguf_files="$(find_cached_gguf_files "$cache_dir")"
  [[ -n "$gguf_files" ]]
}

# Check whether a model (and optionally a specific quant) is already in the cache.
# With no quant, returns 0 if the model directory exists at all.
# With a quant, returns 0 only if GGUF files matching that quant tag are cached.
cache_has_model_or_quant() {
  local cache_dir="$1"
  # ${2:-}: default to empty if $2 is unset; prevents "unbound variable" under set -u.
  local quant="${2:-}"
  if [[ ! -d "$cache_dir" ]]; then
    return 1
  fi
  if [[ -z "$quant" ]]; then
    return 0
  fi
  local matches
  matches="$(find_gguf_by_quant "$cache_dir" "$quant")"
  [[ -n "$matches" ]]
}

# Emit one line per installed quant variant in pipe-delimited format:
#   {model_name}|{quant_tag}|{disk_size}|{backend}
# This is the canonical data format consumed by cmd_list and cmd_remove.
collect_cached_model_entries() {
  local dir
  for dir in "$HF_HUB_DIR"/models--*/; do
    [[ -d "$dir" ]] || continue
    local model_name
    model_name="$(cache_dir_to_model_name "$dir")"

    local gguf_files
    gguf_files="$(find_cached_gguf_files "$dir")"
    if [[ -z "$gguf_files" ]]; then
      # llama.cpp list scope is GGUF-only.
      continue
    fi

    local tag
    while IFS= read -r tag; do
      [[ -z "$tag" ]] && continue
      local matching_files=()
      local f
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        matching_files+=("$f")
      done < <(find_cached_gguf_paths_by_quant "$dir" "$tag")

      # Snapshot entries are symlinks to content-addressed blobs. Multiple
      # revisions can therefore expose the same physical file under different
      # paths. Resolve and deduplicate the targets before measuring so shared
      # blobs are counted once.
      local unique_files=()
      local resolved_file
      for f in "${matching_files[@]}"; do
        resolved_file="$(resolve_link "$f")"
        [[ -n "$resolved_file" ]] || continue
        local already_seen="false"
        local unique_file
        if [[ ${#unique_files[@]} -gt 0 ]]; then
          for unique_file in "${unique_files[@]}"; do
            if [[ "$unique_file" == "$resolved_file" ]]; then
              already_seen="true"
              break
            fi
          done
        fi
        [[ "$already_seen" == "true" ]] || unique_files+=("$resolved_file")
      done

      # du -shL: -s summarize (one total), -h human-readable, -L follow symlinks.
      # du -chL: same but -c adds a grand total line (we grab it with tail -1).
      local size
      if [[ ${#unique_files[@]} -eq 1 ]]; then
        size="$(du -shL "${unique_files[0]}" 2>/dev/null | cut -f1)"
      elif [[ ${#unique_files[@]} -gt 1 ]]; then
        size="$(du -chL "${unique_files[@]}" 2>/dev/null | tail -1 | cut -f1)"
      else
        size='?'
      fi

      printf '%s|%s|%s|llama.cpp\n' "$model_name" "$tag" "$size"
    done < <(_cached_quant_tags "$dir")
  done
}

# Find cached model GGUF file paths in a model's HF cache snapshots directory.
# HuggingFace hub stores downloaded files under snapshots/<revision-hash>/.
# A model may have multiple snapshot revisions, so we glob all of them.
# Auxiliary sidecars such as mmproj and mtp drafts are excluded here.
# Prints one full path per line, deduplicated and sorted.
_find_cached_gguf_paths() {
  local cache_dir="$1"
  local snapshot_dir
  for snapshot_dir in "$cache_dir"/snapshots/*/; do
    # [[ -d ... ]] || continue: skip if the glob matched nothing (nullglob off)
    # or the path isn't actually a directory.
    [[ -d "$snapshot_dir" ]] || continue
    # -type l: also match symlinks, since HF hub stores GGUF files as symlinks
    # pointing to content-addressed blobs under blobs/.
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      _is_auxiliary_gguf_filename "$(basename "$path")" && continue
      printf '%s\n' "$path"
    done < <(find "$snapshot_dir" \( -type f -o -type l \) -name '*.gguf' -print)
  done | sort -u
}

# Return success for GGUF sidecar files that should not be treated as model
# quant variants. llama.cpp may automatically fetch mmproj projectors for
# multimodal models and MTP drafter sidecars; listing them as model quants is
# misleading.
_is_auxiliary_gguf_filename() {
  local filename="$1"
  local stem="${filename%.gguf}"
  local lower
  lower="$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lower" =~ (^|[-._])mmproj($|[-._]) ]]; then
    return 0
  fi

  # MTP sidecars are published as mtp-*.gguf drafts. Keep this narrow so we
  # don't hide a real primary model that merely happens to contain "mtp" in
  # the middle of its quantized filename.
  if _is_mtp_sidecar_gguf_filename "$filename"; then
    return 0
  fi

  return 1
}

# Return success for MTP draft sidecars published as mtp-*.gguf, including
# quantized names such as mtp-Qwen3.8-27B-Q4_0.gguf.
_is_mtp_sidecar_gguf_filename() {
  local filename="$1"
  local stem="${filename%.gguf}"
  local lower
  lower="$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower" == mtp-* ]]
}

# List the distinct quant tags present in a model's cache directory.
# Extracts the quant tag from each GGUF filename and deduplicates.
_cached_quant_tags() {
  local cache_dir="$1"
  local gguf_files
  gguf_files="$(find_cached_gguf_files "$cache_dir")"
  if [[ -z "$gguf_files" ]]; then
    return 0
  fi

  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    extract_quant_from_filename "$fname"
  done <<< "$gguf_files" | sort -u
}
