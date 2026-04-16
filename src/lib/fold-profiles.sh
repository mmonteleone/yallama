# Profile and template helpers for fold.
# shellcheck shell=bash

# Return the resolved profiles directory (env override or default).
# ${FOLD_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}: use the env var if set,
# otherwise fall back to the default. This pattern is used for all overridable dirs.
_profiles_dir() {
  local dir="${FOLD_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}"
  # ${dir/#\~/$HOME}: expand leading tilde (see ensure_llama_in_path).
  dir="${dir/#\~/$HOME}"
  printf '%s' "$dir"
}

# Return the path for a named profile file.
_profile_path() {
  local name="$1"
  printf '%s/%s' "$(_profiles_dir)" "$name"
}

# Return the resolved templates directory (env override or default).
_templates_dir() {
  local dir="${FOLD_TEMPLATES_DIR:-$DEFAULT_TEMPLATES_DIR}"
  dir="${dir/#\~/$HOME}"
  printf '%s' "$dir"
}

# Return the path for a named template file.
_template_path() {
  local name="$1"
  printf '%s/%s' "$(_templates_dir)" "$name"
}

# Print the content of a built-in template, or return 1 if the name is unknown.
_get_builtin_template_content() {
  local name="$1"
  case "$name" in
    chat)
      printf '%s\n' \
        '--temp 0.8' \
        '--ctx-size 8192' \
        '--flash-attn on' \
        '-ngl 999'
      ;;
    code)
      printf '%s\n' \
        '--ctx-size 65536' \
        '--n-predict 4096' \
        '--temp 0.2' \
        '--top-k 20' \
        '--repeat-penalty 1.05' \
        '--flash-attn on' \
        '-ngl 999' \
        '[serve]' \
        '--cache-reuse 256'
      ;;
    *)
      return 1
      ;;
  esac
}

# Print the content of a template (user-defined takes precedence over built-in).
# Dies if the template is not found by either source.
_get_template_content() {
  local name="$1"
  local path
  path="$(_template_path "$name")"
  if [[ -f "$path" ]]; then
    cat "$path"
  elif _get_builtin_template_content "$name"; then
    # ':' (colon): bash no-op. The elif already printed the template to stdout;
    # this empty then-body avoids a syntax error.
    :
  else
    die "template '${name}' not found"
  fi
}

# Validate a template name: alphanumeric, hyphens, underscores only.
# The regex [^a-zA-Z0-9_-] matches any character NOT in the allowed set;
# if it matches, the name is invalid.
_validate_template_name() {
  local name="$1"
  if [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_-] ]]; then
    die "invalid template name '${name}': use only letters, digits, hyphens, and underscores"
  fi
}

# Validate a profile name: alphanumeric, hyphens, underscores only.
_validate_profile_name() {
  local name="$1"
  if [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_-] ]]; then
    die "invalid profile name '${name}': use only letters, digits, hyphens, and underscores"
  fi
}

# Emit one line per profile in pipe-delimited format:
#   {profile_name}|{model_spec}
# Profiles without a model= line are skipped.
collect_profile_entries() {
  local profiles_dir
  profiles_dir="$(_profiles_dir)"
  [[ -d "$profiles_dir" ]] || return 0

  local f
  for f in "$profiles_dir"/*; do
    [[ -f "$f" ]] || continue
    local name model_line
    name="$(basename "$f")"
    model_line="$(grep '^model=' "$f" 2>/dev/null | head -1)"
    model_line="${model_line#model=}"
    [[ -n "$model_line" ]] || continue
    printf '%s|%s\n' "$name" "$model_line"
  done
}

# Emit one line per template in pipe-delimited format:
#   {template_name}|{type}|{default_model}
# type is "built-in" or "user". default_model is "(none)" when absent.
collect_template_entries() {
  local -a builtin_names=( chat code )
  local bname
  for bname in "${builtin_names[@]}"; do
    printf '%s|%s|%s\n' "$bname" 'built-in' '(none)'
  done

  local templates_dir
  templates_dir="$(_templates_dir)"
  [[ -d "$templates_dir" ]] || return 0

  local f
  for f in "$templates_dir"/*; do
    [[ -f "$f" ]] || continue
    local tname model_line
    tname="$(basename "$f")"
    model_line="$(grep '^model=' "$f" 2>/dev/null | head -1)"
    model_line="${model_line#model=}"
    printf '%s|%s|%s\n' "$tname" 'user' "${model_line:-(none)}"
  done
}

# Load a profile file.
# Usage: _load_profile <name> [run|serve]
# Sets REPLY_PROFILE_MODEL and REPLY_PROFILE_ARGS (array).
#
# Profile files use an INI-like section model:
#   - Lines before any [run] / [serve] header are common to both commands.
#   - Lines under [run] are included only when mode is "run".
#   - Lines under [serve] are included only when mode is "serve".
# Each flag line holds one flag or a flag+value pair (e.g. "--ctx-size 8192").
_load_profile() {
  local name="$1"
  local mode="${2:-}"
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found (${path})"

  REPLY_PROFILE_MODEL=""
  REPLY_PROFILE_ARGS=()

  local section="common"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip trailing whitespace (bash extglob pattern *( ) = zero or more spaces).
    line="${line%%*( )}"
    [[ -z "$line" || "$line" == '#'* ]] && continue

    if [[ "$line" == '[run]' ]]; then section="run"; continue; fi
    if [[ "$line" == '[serve]' ]]; then section="serve"; continue; fi

    if [[ "$line" == model=* ]]; then
      REPLY_PROFILE_MODEL="${line#model=}"
      continue
    fi

    if [[ "$section" == "common" || -z "$mode" || "$section" == "$mode" ]]; then
      # read -ra word-splits the line into an array so that multi-token
      # lines like "--ctx-size 8192" become two separate array elements.
      read -ra _flag_words <<< "$line"
      REPLY_PROFILE_ARGS+=("${_flag_words[@]}")
    fi
  done < "$path"

  [[ -n "$REPLY_PROFILE_MODEL" ]] || die "profile '${name}' has no 'model=' line"
}

cmd_profile_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME profile set <NAME> <MODEL_SPEC> [-- <flags...>]
       $SCRIPT_NAME profile set <NAME> <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
       $SCRIPT_NAME profile show <NAME>
       $SCRIPT_NAME profile duplicate <SOURCE> <DEST>

Subcommands:
  set <NAME> <MODEL_SPEC> [-- <flags...>]
      Create or replace a named profile from a model spec.

  set <NAME> <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
      Create or replace a named profile from a template. MODEL_SPEC is
      optional if the template includes a 'model=' line.

  show <NAME>
      Print the profile's model and flags.

  duplicate <SOURCE> <DEST>
      Copy an existing profile to a new name.

Profiles are stored in: \${FOLD_PROFILES_DIR:-~/.config/fold/profiles}
Built-in templates available for 'profile set': chat, code

Optional [run] and [serve] section headers in a profile file scope flags to
only that command. Flags before any section header apply to both.
Example profile file:
  model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
  --ctx-size 65536
  --n-predict 4096
  --temp 0.2
  --top-k 20
  --repeat-penalty 1.05
  --flash-attn on
  -ngl 999
  [serve]
  --cache-reuse 256

Use a profile name instead of a model spec with 'run' or 'serve':
  $SCRIPT_NAME serve coder

Create/update a profile from a built-in template:
  $SCRIPT_NAME profile set mycoder code unsloth/Qwen3.5-27B-GGUF:UD-Q5_K_XL
EOF
}

cmd_profile() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_profile_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    set)             _cmd_profile_set "$@" ;;
    show)            _cmd_profile_show "$@" ;;
    duplicate)       _cmd_profile_duplicate "$@" ;;
    -h|--help) cmd_profile_usage; return 0 ;;
    *)
      echo "Unknown profile subcommand: $subcmd" >&2
      cmd_profile_usage >&2
      return 1
      ;;
  esac
}

cmd_template_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME template show <TEMPLATE>
       $SCRIPT_NAME template set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
       $SCRIPT_NAME template remove <TEMPLATE>

Subcommands:
  show <TEMPLATE>
      Print the content of a template.

  set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
      Create or replace a user-defined template. MODEL_SPEC is optional.

  remove <TEMPLATE>
      Delete a user-defined template. Built-in templates cannot be removed.

Templates are stored in: \${FOLD_TEMPLATES_DIR:-~/.config/fold/templates}
Built-in templates: chat, code
EOF
}

cmd_template() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_template_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local subcmd="$1"
  shift

  case "$subcmd" in
    show)            _cmd_template_show "$@" ;;
    set)             _cmd_template_set "$@" ;;
    remove|rm)       _cmd_template_remove "$@" ;;
    -h|--help) cmd_template_usage; return 0 ;;
    *)
      echo "Unknown template subcommand: $subcmd" >&2
      cmd_template_usage >&2
      return 1
      ;;
  esac
}

_emit_flag_lines_from_args() {
  local args=("$@")
  local i=0
  local nargs=${#args[@]}
  while [[ $i -lt $nargs ]]; do
    local arg="${args[$i]}"
    local next=$(( i + 1 ))
    if [[ "$arg" == -* ]] && [[ $next -lt $nargs ]] && [[ "${args[$next]}" != -* ]]; then
      printf '%s %s\n' "$arg" "${args[$next]}"
      i=$(( i + 2 ))
    else
      printf '%s\n' "$arg"
      i=$(( i + 1 ))
    fi
  done
}

_extract_model_from_template_content() {
  local template_content="$1"
  local line
  while IFS= read -r line; do
    if [[ "$line" == model=* ]]; then
      printf '%s\n' "${line#model=}"
      return 0
    fi
  done <<< "$template_content"
  return 1
}

_write_profile_file() {
  local path="$1"
  local model_spec="$2"
  local template_content="$3"
  shift 3
  local extra_args=("$@")

  {
    printf 'model=%s\n' "$model_spec"
    if [[ -n "$template_content" ]]; then
      local tline
      while IFS= read -r tline; do
        [[ "$tline" == model=* ]] && continue
        printf '%s\n' "$tline"
      done <<< "$template_content"
    fi
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      _emit_flag_lines_from_args "${extra_args[@]}"
    fi
  } > "$path"
}

_cmd_profile_set() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile set <NAME> <MODEL_SPEC> [-- <flags...>]" >&2
    echo "       $SCRIPT_NAME profile set <NAME> <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local name="$1"
  local target="$2"
  shift 2

  _validate_profile_name "$name"

  local template_content=""
  local model_spec=""
  local extra_args=()

  if [[ "$target" == */* ]]; then
    model_spec="$target"
  else
    _validate_template_name "$target"
    template_content="$(_get_template_content "$target")"

    if [[ $# -gt 0 && "$1" != "--" ]]; then
      model_spec="$1"
      shift
    else
      model_spec="$(_extract_model_from_template_content "$template_content" || true)"
    fi

    [[ -n "$model_spec" ]] || die "no model specified: provide a MODEL_SPEC argument or add 'model=' to the template"
  fi

  if [[ $# -gt 0 ]]; then
    [[ "$1" == "--" ]] || die "expected '--' before flags, got: $1"
    shift
    extra_args=("$@")
  fi

  local profiles_dir
  profiles_dir="$(_profiles_dir)"
  mkdir -p "$profiles_dir"

  local path
  path="$(_profile_path "$name")"

  if [[ ${#extra_args[@]} -gt 0 ]]; then
    _write_profile_file "$path" "$model_spec" "$template_content" "${extra_args[@]}"
  else
    _write_profile_file "$path" "$model_spec" "$template_content"
  fi
  echo "Profile '${name}' saved."
}

_cmd_profile_show() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile show <NAME>" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local name="$1"
  _validate_profile_name "$name"

  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found"

  cat "$path"
}

remove_profile_by_name() {
  local name="$1"
  _validate_profile_name "$name"

  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found"

  rm -f "$path"
  echo "Profile '${name}' removed."
}

_cmd_profile_duplicate() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile duplicate <SOURCE> <DEST>" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local src="$1"
  local dst="$2"

  _validate_profile_name "$src"
  _validate_profile_name "$dst"

  local src_path dst_path
  src_path="$(_profile_path "$src")"
  dst_path="$(_profile_path "$dst")"

  [[ -f "$src_path" ]] || die "source profile '${src}' not found"
  [[ ! -f "$dst_path" ]] || die "destination profile '${dst}' already exists; remove it first"

  cp "$src_path" "$dst_path"
  echo "Profile '${src}' duplicated to '${dst}'."
}

_cmd_template_show() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME template show <TEMPLATE>" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local name="$1"
  _validate_template_name "$name"
  _get_template_content "$name"
}

_cmd_template_set() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME template set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local name="$1"
  shift

  _validate_template_name "$name"

  local model_spec=""
  # Positional sniffing: if the next argument is not '--' and doesn't start
  # with '-', treat it as an optional MODEL_SPEC before any flags.
  if [[ $# -gt 0 && "$1" != "--" && "$1" != -* ]]; then
    model_spec="$1"
    shift
  fi

  local extra_args=()
  if [[ $# -gt 0 ]]; then
    [[ "$1" == "--" ]] || die "expected '--' before flags, got: $1"
    shift
    extra_args=("$@")
  fi

  local templates_dir
  templates_dir="$(_templates_dir)"
  mkdir -p "$templates_dir"

  local path
  path="$(_template_path "$name")"

  {
    if [[ -n "$model_spec" ]]; then
      printf 'model=%s\n' "$model_spec"
    fi
    if [[ ${#extra_args[@]} -gt 0 ]]; then
      _emit_flag_lines_from_args "${extra_args[@]}"
    fi
  } > "$path"

  echo "Template '${name}' saved."
}

_cmd_template_remove() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME template remove <TEMPLATE>" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local name="$1"
  _validate_template_name "$name"

  # Guard: built-in templates are compiled into the script and can't be deleted.
  if _get_builtin_template_content "$name" >/dev/null 2>&1; then
    die "cannot remove built-in template '${name}'"
  fi

  local path
  path="$(_template_path "$name")"
  [[ -f "$path" ]] || die "template '${name}' not found"

  rm -f "$path"
  echo "Template '${name}' removed."
}
