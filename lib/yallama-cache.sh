# Cache and quant helpers for yallama.

# Parse "user/model[:quant]" into REPLY_MODEL and REPLY_QUANT globals.
_parse_model_spec() {
  local spec="$1"
  REPLY_MODEL="${spec%%:*}"
  if [[ "$spec" == *:* ]]; then
    REPLY_QUANT="${spec#*:}"
  else
    REPLY_QUANT=""
  fi
}

# Extract a quant tag from a GGUF filename for display and matching.
# e.g., "gemma-4-26B-A4B-it-UD-Q6_K.gguf" -> "UD-Q6_K"
# Falls back to the full basename (minus .gguf) if no known pattern matches.
extract_quant_from_filename() {
  local filename="$1"
  local base="${filename%.gguf}"
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

# Find cached GGUF file paths in a model's HF cache snapshots directory.
# Prints one full path per line, deduplicated and sorted.
_find_cached_gguf_paths() {
  local cache_dir="$1"
  local snapshot_dir
  for snapshot_dir in "$cache_dir"/snapshots/*/; do
    [[ -d "$snapshot_dir" ]] || continue
    find "$snapshot_dir" \( -type f -o -type l \) -name '*.gguf' -print
  done | sort -u
}

# Find cached GGUF files in a model's HF cache snapshots directory.
# Prints one basename per line, deduplicated and sorted.
_find_cached_gguf_files() {
  local cache_dir="$1"
  _find_cached_gguf_paths "$cache_dir" | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    basename "$f"
  done | sort -u
}

# Find cached GGUF filenames whose extracted quant tag matches the given tag.
# Prints matching basenames, one per line.
_find_gguf_by_quant() {
  local cache_dir="$1"
  local quant="$2"
  local normalized_quant
  normalized_quant="$(normalize_quant_tag "$quant")"
  _find_cached_gguf_files "$cache_dir" | while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    local tag
    tag="$(extract_quant_from_filename "$fname")"
    if [[ "$(normalize_quant_tag "$tag")" == "$normalized_quant" ]]; then
      printf '%s\n' "$fname"
    fi
  done
}

# Find cached GGUF file paths whose extracted quant tag matches the given tag.
# Prints matching full paths, one per line.
_find_cached_gguf_paths_by_quant() {
  local cache_dir="$1"
  local quant="$2"
  local normalized_quant
  normalized_quant="$(normalize_quant_tag "$quant")"
  _find_cached_gguf_paths "$cache_dir" | while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    local tag
    tag="$(extract_quant_from_filename "$(basename "$path")")"
    if [[ "$(normalize_quant_tag "$tag")" == "$normalized_quant" ]]; then
      printf '%s\n' "$path"
    fi
  done
}

# Resolve a symlink to its absolute target path (follows one level).
_resolve_link() {
  local path="$1"
  if [[ -L "$path" ]]; then
    local dir target
    dir="$(dirname "$path")"
    target="$(readlink "$path")"
    if [[ "$target" != /* ]]; then
      target="${dir}/${target}"
    fi
    (cd "$(dirname "$target")" 2>/dev/null && printf '%s/%s' "$PWD" "$(basename "$target")")
  else
    printf '%s' "$path"
  fi
}

# Remove GGUF files (symlinks + backing blobs) matching a quant tag from the cache.
# Returns 0 if at least one file was removed, 1 otherwise.
_remove_quant_files() {
  local cache_dir="$1"
  local quant="$2"
  local removed=0
  local f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ -L "$f" ]]; then
      local blob_path
      blob_path="$(_resolve_link "$f")"
      if [[ -f "$blob_path" ]]; then
        rm -f "$blob_path"
      fi
    fi
    rm -f "$f"
    removed=$((removed + 1))
  done < <(_find_cached_gguf_paths_by_quant "$cache_dir" "$quant")
  [[ $removed -gt 0 ]]
}

# Convert "USER/MODEL" -> "${HF_HUB_DIR}/models--USER--MODEL"
model_name_to_cache_dir() {
  local model_name="$1"
  local user="${model_name%%/*}"
  local model="${model_name#*/}"
  if [[ -z "$user" || -z "$model" || "$model" == */* ]]; then
    die "invalid model name '${model_name}': expected format USER/MODEL"
  fi
  printf '%s/models--%s--%s' "$HF_HUB_DIR" "$user" "$model"
}

cache_dir_to_model_name() {
  local cache_dir="$1"
  local entry
  entry="$(basename "$cache_dir")"
  entry="${entry#models--}"
  printf '%s\n' "${entry/--//}"
}

cached_quant_tags() {
  local cache_dir="$1"
  local gguf_files
  gguf_files="$(_find_cached_gguf_files "$cache_dir")"
  if [[ -z "$gguf_files" ]]; then
    return 0
  fi

  while IFS= read -r fname; do
    [[ -z "$fname" ]] && continue
    extract_quant_from_filename "$fname"
  done <<< "$gguf_files" | sort -u
}

cache_has_model_or_quant() {
  local cache_dir="$1"
  local quant="${2:-}"
  if [[ ! -d "$cache_dir" ]]; then
    return 1
  fi
  if [[ -z "$quant" ]]; then
    return 0
  fi
  local matches
  matches="$(_find_gguf_by_quant "$cache_dir" "$quant")"
  [[ -n "$matches" ]]
}

collect_cached_model_entries() {
  local dir
  for dir in "$HF_HUB_DIR"/models--*/; do
    [[ -d "$dir" ]] || continue
    local model_name
    model_name="$(cache_dir_to_model_name "$dir")"

    local gguf_files
    gguf_files="$(_find_cached_gguf_files "$dir")"
    if [[ -z "$gguf_files" ]]; then
      local size
      size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
      printf '%s||%s\n' "$model_name" "$size"
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
      done < <(_find_cached_gguf_paths_by_quant "$dir" "$tag")

      local size
      if [[ ${#matching_files[@]} -eq 1 ]]; then
        size="$(du -shL "${matching_files[0]}" 2>/dev/null | cut -f1)"
      elif [[ ${#matching_files[@]} -gt 1 ]]; then
        size="$(du -chL "${matching_files[@]}" 2>/dev/null | tail -1 | cut -f1)"
      else
        size='?'
      fi

      printf '%s|%s|%s\n' "$model_name" "$tag" "$size"
    done < <(cached_quant_tags "$dir")
  done
}

model_is_in_use() {
  local cache_dir="$1"
  local pids
  pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /llama-(cli|server)$/ {print $1}')"
  [[ -z "$pids" ]] && return 1

  if command -v lsof >/dev/null 2>&1; then
    local pid_list
    pid_list="$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
    lsof -p "$pid_list" 2>/dev/null | grep -qF "$cache_dir"
  else
    local pid
    while IFS= read -r pid; do
      [[ -z "$pid" ]] && continue
      grep -qF "$cache_dir" "/proc/${pid}/maps" 2>/dev/null && return 0
    done <<< "$pids"
    return 1
  fi
}

quant_is_in_use() {
  local cache_dir="$1"
  local model_name="$2"
  local quant="$3"
  local qf qblob
  while IFS= read -r qf; do
    [[ -z "$qf" ]] && continue
    if model_is_in_use "$qf"; then
      die "cannot remove '${model_name}:${quant}': it is currently in use by llama-cli or llama-server."
    fi
    if [[ -L "$qf" ]]; then
      qblob="$(_resolve_link "$qf")"
      if [[ -n "$qblob" ]] && model_is_in_use "$qblob"; then
        die "cannot remove '${model_name}:${quant}': it is currently in use by llama-cli or llama-server."
      fi
    fi
  done < <(_find_cached_gguf_paths_by_quant "$cache_dir" "$quant")
}
