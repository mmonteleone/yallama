# Cache and quant helpers for yallama.
# shellcheck shell=bash

# Parse "user/model[:quant]" into globals REPLY_MODEL and REPLY_QUANT.
# Uses bash parameter expansion operators:
#   %%:*  — remove the longest suffix matching ":*"  → everything before the first ':'
#   #*:   — remove the shortest prefix matching "*:" → everything after the first ':'
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

# Find cached GGUF file paths in a model's HF cache snapshots directory.
# HuggingFace hub stores downloaded files under snapshots/<revision-hash>/.
# A model may have multiple snapshot revisions, so we glob all of them.
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
    find "$snapshot_dir" \( -type f -o -type l \) -name '*.gguf' -print
  done | sort -u
}

# Find cached GGUF files in a model's HF cache snapshots directory.
# Prints one basename per line, deduplicated and sorted.
# 'while IFS= read -r': read one line at a time with no field-splitting (IFS=)
# and no backslash interpretation (-r). This is the safe idiom for processing
# lines that may contain spaces or special characters.
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

# Resolve a symlink to its absolute target path using a subshell cd, avoiding
# a hard dependency on realpath (not available on all systems).
# The (cd ... && printf) runs in a subshell so the working directory change
# doesn't leak into the caller. $PWD after cd gives the canonical absolute path.
_resolve_link() {
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
_remove_quant_files() {
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
      blob_path="$(_resolve_link "$f")"
      if [[ -f "$blob_path" ]]; then
        rm -f "$blob_path"
      fi
    fi
    rm -f "$f"
    removed=$((removed + 1))
  done < <(_find_cached_gguf_paths_by_quant "$cache_dir" "$quant")
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

# List the distinct quant tags present in a model's cache directory.
# Extracts the quant tag from each GGUF filename and deduplicates.
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
  matches="$(_find_gguf_by_quant "$cache_dir" "$quant")"
  [[ -n "$matches" ]]
}

# Emit one line per installed quant variant in pipe-delimited format:
#   {model_name}|{quant_tag}|{disk_size}
# Models with no GGUF files (e.g. non-GGUF repos) emit:
#   {model_name}||{disk_size}   (empty quant field)
# This is the canonical data format consumed by cmd_list and cmd_remove.
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

      # du -shL: -s summarize (one total), -h human-readable, -L follow symlinks.
      # du -chL: same but -c adds a grand total line (we grab it with tail -1).
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

# Check whether any running llama-cli or llama-server process has open files
# inside cache_dir. Uses lsof where available (e.g. macOS, most Linux distros);
# falls back to /proc/PID/maps on systems where lsof is absent.
model_is_in_use() {
  local cache_dir="$1"
  local pids
  # Find PIDs of running llama-cli and llama-server processes.
  # 'ps -eo pid=,comm=': list all processes with just PID and command name
  # (the trailing '=' suppresses the header line).
  pids="$(ps -eo pid=,comm= 2>/dev/null | awk '$2 ~ /llama-(cli|server)$/ {print $1}')"
  [[ -z "$pids" ]] && return 1

  if command -v lsof >/dev/null 2>&1; then
    local pid_list
    # lsof -p needs a comma-separated PID list; join newlines with tr and
    # strip the trailing comma with sed.
    pid_list="$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
    # grep -qF: -q quiet (just set exit code), -F fixed-string (no regex).
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

# Safety check before removing a specific quant: verify none of its files
# are open by a running llama process. Checks both the symlink path in
# snapshots/ and the resolved blob path, since the process may have opened
# either one.
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

# ── list ──────────────────────────────────────────────────────────────────────

cmd_list_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME list [--quiet] [--json]
       $SCRIPT_NAME ls   [--quiet] [--json]

Lists cached HuggingFace models. For GGUF models, each downloaded quant
variant is shown as a separate row (e.g. user/model:Q4_K_M).

Options:
  --quiet   Print only model[:quant] identifiers, one per line. Useful for piping.
  --json    Output as a JSON array with 'name', 'quant', and 'size' fields.
EOF
}

cmd_list() {
  local QUIET="false"
  local JSON="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet)   QUIET="true"; shift ;;
      --json)    JSON="true"; shift ;;
      -h|--help) cmd_list_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_list_usage >&2; return 1 ;;
    esac
  done

  if [[ ! -d "$HF_HUB_DIR" ]]; then
    if [[ "$JSON" == "true" ]]; then
      echo "[]"
    else
      echo "No models found (${HF_HUB_DIR} does not exist)."
    fi
    return 0
  fi

  local found=0
  local entries=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    entries+=("$entry")
    found=1
  done < <(collect_cached_model_entries)

  if [[ "$found" -eq 0 ]]; then
    if [[ "$JSON" == "true" ]]; then
      echo "[]"
    else
      echo "No models found."
    fi
    return 0
  fi

  if [[ "$JSON" == "true" ]]; then
    # jq -R: read each input line as a raw JSON string (not parsed JSON).
    # split("|") turns the pipe-delimited line into an array of three fields.
    # jq -s: slurp all individual JSON objects into a single JSON array.
    printf '%s\n' "${entries[@]}" \
      | jq -R 'split("|") | {name: .[0], quant: (if .[1] == "" then null else .[1] end), size: .[2]}' \
      | jq -s '.'
  elif [[ "$QUIET" == "true" ]]; then
    local e
    for e in "${entries[@]}"; do
      local name quant
      # Extract pipe-delimited fields using the same %%|* / #*| operators
      # as _parse_model_spec, but with '|' as the delimiter instead of ':'.
      name="${e%%|*}"
      local rest="${e#*|}"
      quant="${rest%%|*}"
      if [[ -n "$quant" ]]; then
        echo "${name}:${quant}"
      else
        echo "$name"
      fi
    done
  else
    printf '%-55s  %s\n' "MODEL" "SIZE"
    printf '%-55s  %s\n' "-----" "----"
    local e
    for e in "${entries[@]}"; do
      local name quant size display_name
      name="${e%%|*}"
      local rest="${e#*|}"
      quant="${rest%%|*}"
      size="${rest#*|}"
      if [[ -n "$quant" ]]; then
        display_name="${name}:${quant}"
      else
        display_name="$name"
      fi
      printf '%-55s  %s\n' "$display_name" "$size"
    done
  fi
}

# ── remove ────────────────────────────────────────────────────────────────────

cmd_remove_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME remove <MODEL_NAME>[:<QUANT>] [--force]
       $SCRIPT_NAME rm <MODEL_NAME>[:<QUANT>] [--force]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  QUANT         Optional quant tag to remove only a specific variant
                (e.g. Q4_K_M, UD-Q6_K). Without it, the entire model is removed.

Use '$SCRIPT_NAME list' to see available quant tags.

Deletes the locally cached model or quant variant. Refuses if the model is
currently in use by llama-cli or llama-server.

Options:
  --force       Skip the confirmation prompt.
EOF
}

cmd_remove() {
  # Idiomatic help/no-args guard used throughout yallama:
  # With no args: print usage to stderr and return 1 (error).
  # With -h/--help: print usage to stdout and return 0 (success).
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_remove_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local model_spec="$1"
  local force="false"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force)   force="true"; shift ;;
      -h|--help) cmd_remove_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_remove_usage >&2; return 1 ;;
    esac
  done

  local model_name quant
  _parse_model_spec "$model_spec"
  model_name="$REPLY_MODEL"
  quant="$REPLY_QUANT"

  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"

  if [[ ! -d "$cache_dir" ]]; then
    die "model not found: ${model_name} (expected at ${cache_dir})"
  fi

  if [[ -n "$quant" ]]; then
    # ── Remove a single quant variant ──
    local matching_files
    matching_files="$(_find_gguf_by_quant "$cache_dir" "$quant")"
    if [[ -z "$matching_files" ]]; then
      die "no cached files matching quant '${quant}' found for model '${model_name}'"
    fi

    quant_is_in_use "$cache_dir" "$model_name" "$quant"

    confirm_destructive_action "removing quant '${quant}' from '${model_name}'" "$force" || return 1

    echo "Removing quant: ${model_name}:${quant}"
    _remove_quant_files "$cache_dir" "$quant"

    local remaining
    remaining="$(_find_cached_gguf_files "$cache_dir")"
    if [[ -z "$remaining" ]]; then
      echo "No remaining quants. Removing model cache."
      rm -rf "$cache_dir"
    fi
    echo "Done."
  else
    # ── Remove the entire model (all quants) ──
    if model_is_in_use "$cache_dir"; then
      die "cannot remove '${model_name}': it is currently in use by llama-cli or llama-server."
    fi

    local all_quants quant_list=()
    all_quants="$(_find_cached_gguf_files "$cache_dir")"
    if [[ -n "$all_quants" ]]; then
      while IFS= read -r fname; do
        [[ -z "$fname" ]] && continue
        local tag
        tag="$(extract_quant_from_filename "$fname")"
        quant_list+=("$tag")
      done < <(printf '%s\n' "$all_quants" | sort -u)
    fi

    echo "The following quant variants will be removed:"
    if [[ ${#quant_list[@]} -gt 0 ]]; then
      local q
      for q in "${quant_list[@]}"; do
        printf '  %s:%s\n' "$model_name" "$q"
      done
    else
      printf '  %s  (no GGUF variants found)\n' "$model_name"
    fi
    echo

    confirm_destructive_action "removing cached model '${model_name}'" "$force" || return 1

    echo "Removing model: $model_name"
    rm -rf "$cache_dir"
    echo "Done."
  fi
}
