# Profile and template helpers for yallama.

# Return the resolved profiles directory (env override or default).
# ${YALLAMA_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}: use the env var if set,
# otherwise fall back to the default. This pattern is used for all overridable dirs.
_profiles_dir() {
  local dir="${YALLAMA_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}"
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
  local dir="${YALLAMA_TEMPLATES_DIR:-$DEFAULT_TEMPLATES_DIR}"
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
       $SCRIPT_NAME profile list
       $SCRIPT_NAME profile show <NAME>
       $SCRIPT_NAME profile remove <NAME>
       $SCRIPT_NAME profile duplicate <SOURCE> <DEST>
       $SCRIPT_NAME profile new <NAME> <TEMPLATE> [<MODEL_SPEC>]
       $SCRIPT_NAME profile templates
       $SCRIPT_NAME profile template-show <TEMPLATE>
       $SCRIPT_NAME profile template-set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
       $SCRIPT_NAME profile template-remove <TEMPLATE>

Subcommands:
  set <NAME> <MODEL_SPEC> [-- <flags...>]
      Create or replace a named profile. MODEL_SPEC is user/model[:quant].
      Pass llama-cli / llama-server flags after '--'. All flags are written
      to the common section (applied to both run and serve). To add
      command-specific flags, edit the profile file directly and add
      [run] or [serve] section headers.

  list
      List all saved profiles.

  show <NAME>
      Print the profile's model and flags.

  remove <NAME>
      Delete a profile.

  duplicate <SOURCE> <DEST>
      Copy an existing profile to a new name.

  new <NAME> <TEMPLATE> [<MODEL_SPEC>]
      Create a new profile from a template. MODEL_SPEC overrides any default
      model embedded in the template. Errors if the profile already exists.

  templates
      List all available templates (built-in and user-defined).

  template-show <TEMPLATE>
      Print the content of a template.

  template-set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]
      Create or replace a user-defined template. MODEL_SPEC is optional.

  template-remove <TEMPLATE>
      Delete a user-defined template. Built-in templates cannot be removed.

Profiles are stored in: \${YALLAMA_PROFILES_DIR:-~/.config/yallama/profiles}
Templates are stored in: \${YALLAMA_TEMPLATES_DIR:-~/.config/yallama/templates}

Built-in templates: chat, code

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

Create a profile from a built-in template:
  $SCRIPT_NAME  profile new mycoder code unsloth/Qwen3.5-27B-GGUF:UD-Q5_K_XL
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
    list)            _cmd_profile_list "$@" ;;
    show)            _cmd_profile_show "$@" ;;
    remove)          _cmd_profile_remove "$@" ;;
    duplicate)       _cmd_profile_duplicate "$@" ;;
    new)             _cmd_profile_new "$@" ;;
    templates)       _cmd_profile_templates "$@" ;;
    template-show)   _cmd_profile_template_show "$@" ;;
    template-set)    _cmd_profile_template_set "$@" ;;
    template-remove) _cmd_profile_template_remove "$@" ;;
    -h|--help) cmd_profile_usage; return 0 ;;
    *)
      echo "Unknown profile subcommand: $subcmd" >&2
      cmd_profile_usage >&2
      return 1
      ;;
  esac
}

_cmd_profile_set() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile set <NAME> <MODEL_SPEC> [-- <flags...>]" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local name="$1"
  local model_spec="$2"
  shift 2

  _validate_profile_name "$name"

  local extra_args=()
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

  # { ... } > "$path": brace group redirects all enclosed output to the file.
  # This is more efficient than multiple individual redirects and ensures
  # the file is written atomically (opened once, closed once).
  {
    printf 'model=%s\n' "$model_spec"
    # Write flags one-per-line or as flag+value pairs on one line
    # (e.g. "--ctx-size 8192") to keep the profile file human-readable.
    # Walk the extra_args array: if arg[i] starts with '-' and arg[i+1]
    # does not, treat them as a flag+value pair and emit them together.
    local i=0
    local _nargs=${#extra_args[@]}
    while [[ $i -lt $_nargs ]]; do
      local _arg="${extra_args[$i]}"
      local _next=$(( i + 1 ))
      if [[ "$_arg" == -* ]] && [[ $_next -lt $_nargs ]] && [[ "${extra_args[$_next]}" != -* ]]; then
        printf '%s %s\n' "$_arg" "${extra_args[$_next]}"
        i=$(( i + 2 ))
      else
        printf '%s\n' "$_arg"
        i=$(( i + 1 ))
      fi
    done
  } > "$path"

  echo "Profile '${name}' saved."
}

_cmd_profile_list() {
  local profiles_dir
  profiles_dir="$(_profiles_dir)"

  if [[ ! -d "$profiles_dir" ]]; then
    echo "No profiles found."
    return 0
  fi

  local found=0
  local f
  for f in "$profiles_dir"/*; do
    [[ -f "$f" ]] || continue
    local name model_line
    name="$(basename "$f")"
    model_line="$(grep '^model=' "$f" 2>/dev/null | head -1)"
    model_line="${model_line#model=}"
    printf '%-20s  %s\n' "$name" "$model_line"
    found=1
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No profiles found."
  fi
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

_cmd_profile_remove() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile remove <NAME>" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

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

_cmd_profile_new() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile new <NAME> <TEMPLATE> [<MODEL_SPEC>]" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local name="$1"
  local template_name="$2"
  local model_arg="${3:-}"

  _validate_profile_name "$name"
  _validate_template_name "$template_name"

  local template_content
  template_content="$(_get_template_content "$template_name")"

  local model=""
  if [[ -n "$model_arg" ]]; then
    model="$model_arg"
  else
    local tline
    while IFS= read -r tline; do
      if [[ "$tline" == model=* ]]; then
        model="${tline#model=}"
        break
      fi
    done <<< "$template_content"
  fi
  [[ -n "$model" ]] || die "no model specified: provide a MODEL_SPEC argument or add 'model=' to the template"

  local profiles_dir
  profiles_dir="$(_profiles_dir)"
  local path
  path="$(_profile_path "$name")"

  [[ ! -f "$path" ]] || die "profile '${name}' already exists; remove it first or use 'profile set' to overwrite"

  mkdir -p "$profiles_dir"

  # Build the profile file: model= line first, then all template lines
  # except any embedded model= line (which was overridden above).
  {
    printf 'model=%s\n' "$model"
    while IFS= read -r tline; do
      [[ "$tline" == model=* ]] && continue
      printf '%s\n' "$tline"
    done <<< "$template_content"
  } > "$path"

  echo "Profile '${name}' created from template '${template_name}'."
}

_cmd_profile_templates() {
  # 'local -a': explicitly declare a local array variable.
  local -a builtin_names=( chat code )
  local templates_dir
  templates_dir="$(_templates_dir)"

  printf '%-20s  %-10s  %s\n' 'NAME' 'TYPE' 'DEFAULT MODEL'
  printf '%-20s  %-10s  %s\n' '----' '----' '-------------'

  local bname
  for bname in "${builtin_names[@]}"; do
    printf '%-20s  %-10s  %s\n' "$bname" 'built-in' '(none)'
  done

  if [[ -d "$templates_dir" ]]; then
    local f
    for f in "$templates_dir"/*; do
      [[ -f "$f" ]] || continue
      local tname model_line
      tname="$(basename "$f")"
      model_line="$(grep '^model=' "$f" 2>/dev/null | head -1)"
      model_line="${model_line#model=}"
      printf '%-20s  %-10s  %s\n' "$tname" 'user' "${model_line:-(none)}"
    done
  fi
}

_cmd_profile_template_show() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile template-show <TEMPLATE>" >&2
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local name="$1"
  _validate_template_name "$name"
  _get_template_content "$name"
}

_cmd_profile_template_set() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile template-set <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]" >&2
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
    local i=0
    local _nargs=${#extra_args[@]}
    while [[ $i -lt $_nargs ]]; do
      local _arg="${extra_args[$i]}"
      local _next=$(( i + 1 ))
      if [[ "$_arg" == -* ]] && [[ $_next -lt $_nargs ]] && [[ "${extra_args[$_next]}" != -* ]]; then
        printf '%s %s\n' "$_arg" "${extra_args[$_next]}"
        i=$(( i + 2 ))
      else
        printf '%s\n' "$_arg"
        i=$(( i + 1 ))
      fi
    done
  } > "$path"

  echo "Template '${name}' saved."
}

_cmd_profile_template_remove() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME profile template-remove <TEMPLATE>" >&2
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
