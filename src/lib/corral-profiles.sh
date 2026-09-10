# Profile and template helpers for corral.
#
# Manages named run/serve profiles and templates stored on disk. Provides:
#   - Public helpers: profile_path(), load_profile(), collect_profile_entries(),
#     collect_template_entries(), remove_profile_by_name()
#   - Directory resolution: _profiles_dir(), _templates_dir() (env-overridable)
#   - Name validation: _validate_name() → _validate_profile_name(), _validate_template_name()
#   - Template lookup: _get_template_content() (user-defined overrides built-in)
#   - Profile I/O: load_profile() with INI-like section filtering by command and backend
#   - Section matching: _section_matches() — [run], [serve], [mlx], [llama.cpp], [mlx.run], etc.
#   - Entry collection: collect_profile_entries(), collect_template_entries()
#   - Commands: cmd_profile, cmd_template, cmd_copy
#
# Built-in templates are inlined by tools/build.sh between BEGIN/END markers;
# in dev mode, they are read from src/templates/*.conf.
# shellcheck shell=bash

# Return the path for a named profile file.
profile_path() {
  local name="$1"
  printf '%s/%s' "$(_profiles_dir)" "$name"
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
    model_line="$(grep '^model=' "$f" 2>/dev/null | head -1 || true)"
    model_line="${model_line#model=}"
    [[ -n "$model_line" ]] || continue
    printf '%s|%s\n' "$name" "$model_line"
  done
}

_builtin_template_names() {
# BEGIN_BUILTIN_TEMPLATE_NAMES
  # In dev mode, discover built-in template names from src/templates/.
  # At build time, tools/build.sh replaces this block with a static list.
  local -a builtin_names=()
  local _btmpl_dir
  _btmpl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../templates"
  local _btf
  for _btf in "${_btmpl_dir}"/*.conf; do
    [[ -f "$_btf" ]] || continue
    builtin_names+=("$(basename "$_btf" .conf)")
  done
# END_BUILTIN_TEMPLATE_NAMES
  printf '%s\n' "${builtin_names[@]}"
}

_builtin_templates_usage_list() {
  local names=()
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    names+=("$name")
  done < <(_builtin_template_names)
  ((${#names[@]} > 0)) || return 0

  local i
  for ((i = 0; i < ${#names[@]}; i++)); do
    ((i > 0)) && printf ', '
    printf '%s' "${names[$i]}"
  done
}

# Emit one line per template in pipe-delimited format:
#   {template_name}|{type}|{default_model}
# type is "built-in" or "user". default_model is "(none)" when absent.
collect_template_entries() {
  local bname bcontent bmodel
  while IFS= read -r bname; do
    [[ -n "$bname" ]] || continue
    bcontent="$(_get_builtin_template_content "$bname")"
    bmodel="$(_extract_model_from_template_content "$bcontent" || true)"
    printf '%s|%s|%s\n' "$bname" 'built-in' "${bmodel:-(none)}"
  done < <(_builtin_template_names)

  local templates_dir
  templates_dir="$(_templates_dir)"
  [[ -d "$templates_dir" ]] || return 0

  local f
  for f in "$templates_dir"/*; do
    [[ -f "$f" ]] || continue
    local tname model_line
    tname="$(basename "$f")"
    model_line="$(grep '^model=' "$f" 2>/dev/null | head -1 || true)"
    model_line="${model_line#model=}"
    printf '%s|%s|%s\n' "$tname" 'user' "${model_line:-(none)}"
  done
}

# Load a profile file.
# Usage: load_profile <name> [run|serve] [mlx|llama.cpp]
# Sets REPLY_PROFILE_MODEL and REPLY_PROFILE_ARGS (array).
load_profile() {
  local name="$1"
  local mode="${2:-}"
  local backend="${3:-}"
  local path
  path="$(profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found (${path})"

  REPLY_PROFILE_MODEL=""
  REPLY_PROFILE_ARGS=()

  local section="common"
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(_strip_profile_line_comment "$line")"
    [[ -z "$line" ]] && continue

    case "$line" in
      '[run]')             section="run";             continue ;;
      '[serve]')           section="serve";           continue ;;
      '[mlx]')             section="mlx";             continue ;;
      '[llama.cpp]')       section="llama.cpp";       continue ;;
      '[mlx.run]')         section="mlx.run";         continue ;;
      '[mlx.serve]')       section="mlx.serve";       continue ;;
      '[llama.cpp.run]')   section="llama.cpp.run";   continue ;;
      '[llama.cpp.serve]') section="llama.cpp.serve"; continue ;;
    esac

    if [[ "$line" == model=* ]]; then
      REPLY_PROFILE_MODEL="${line#model=}"
      continue
    fi

    if ! _section_matches "$section" "$mode" "$backend"; then
      continue
    fi

    read -ra _flag_words <<< "$line"
    REPLY_PROFILE_ARGS+=("${_flag_words[@]}")
  done < "$path"

  [[ -n "$REPLY_PROFILE_MODEL" ]] || die "profile '${name}' has no 'model=' line"
}

cmd_profile_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME profile <NAME> <MODEL_SPEC> [-- <flags...>]
       $SCRIPT_NAME profile <NAME> <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]

Create or replace a named profile from a model spec or template.
MODEL_SPEC is optional when using a template that includes a 'model=' line.

Profiles are stored in: \${CORRAL_PROFILES_DIR:-~/.config/corral/profiles}
Built-in templates available for 'profile': $(_builtin_templates_usage_list)

The backend (llama.cpp or mlx) is inferred automatically from the model spec
when running or serving a profile. No explicit backend declaration is needed.

Section headers scope flags to a specific command, backend, or both:
  [run]              Flags for 'run' only (any backend).
  [serve]            Flags for 'serve' only (any backend).
  [mlx]              Flags for MLX backend only (any command).
  [llama.cpp]        Flags for llama.cpp backend only (any command).
  [mlx.run]          Flags for MLX + run only.
  [mlx.serve]        Flags for MLX + serve only.
  [llama.cpp.run]    Flags for llama.cpp + run only.
  [llama.cpp.serve]  Flags for llama.cpp + serve only.
Flags before any section header apply to all commands and backends.

Example profile file:
  model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
  --temp 0.2
  [llama.cpp]
  --ctx-size 65536
  --flash-attn on
  -ngl 999
  [llama.cpp.serve]
  --cache-reuse 256

Use a profile name instead of a model spec with 'run' or 'serve':
  $SCRIPT_NAME serve coder

Create/update a profile from a built-in template:
  $SCRIPT_NAME profile myqwen qwen unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M
EOF
}

cmd_profile() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_profile_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  _cmd_profile_set "$@"
}

cmd_template_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME template <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]

Create or replace a user-defined template. MODEL_SPEC is optional.

Templates are stored in: \${CORRAL_TEMPLATES_DIR:-~/.config/corral/templates}
Built-in templates: $(_builtin_templates_usage_list)
EOF
}

cmd_template() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_template_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  _cmd_template_set "$@"
}

cmd_copy_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME copy <SOURCE> <DEST>
       $SCRIPT_NAME cp <SOURCE> <DEST>

Copy an existing profile to a new profile, or copy a built-in/user template
to a new user-defined template.
EOF
}

remove_profile_by_name() {
  local name="$1"
  _validate_profile_name "$name"

  local path
  path="$(profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found"

  rm -f "$path"
  echo "Profile '${name}' removed."
}

# Return the resolved profiles directory (env override or default).
# ${CORRAL_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}: use the env var if set,
# otherwise fall back to the default. This pattern is used for all overridable dirs.
_profiles_dir() {
  local dir="${CORRAL_PROFILES_DIR:-$DEFAULT_PROFILES_DIR}"
  printf '%s' "$(normalize_dir_path "$dir")"
}

# Return the resolved templates directory (env override or default).
_templates_dir() {
  local dir="${CORRAL_TEMPLATES_DIR:-$DEFAULT_TEMPLATES_DIR}"
  printf '%s' "$(normalize_dir_path "$dir")"
}

# Return the path for a named template file.
_template_path() {
  local name="$1"
  printf '%s/%s' "$(_templates_dir)" "$name"
}

# Print the content of a built-in template, or return 1 if the name is unknown.
_get_builtin_template_content() {
  local name="$1"
# BEGIN_BUILTIN_TEMPLATES
  # In dev mode (sourced from src/), read template content from src/templates/.
  # At build time, tools/build.sh replaces this block with inlined content.
  local _tmpl_dir
  _tmpl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../templates"
  if [[ -f "${_tmpl_dir}/${name}.conf" ]]; then
    cat "${_tmpl_dir}/${name}.conf"
    return 0
  fi
  return 1
# END_BUILTIN_TEMPLATES
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

# Validate a user-supplied identifier: must consist of alphanumeric characters,
# hyphens, and underscores only. The regex [^a-zA-Z0-9_-] matches any character
# NOT in the allowed set; if it matches, the name is invalid.
# Used by both profile and template name validation.
_validate_name() {
  local kind="$1"
  local name="$2"
  if [[ -z "$name" || "$name" =~ [^a-zA-Z0-9_-] ]]; then
    die "invalid ${kind} name '${name}': use only letters, digits, hyphens, and underscores"
  fi
}

# Validate a template name: alphanumeric, hyphens, underscores only.
_validate_template_name() { _validate_name "template" "$1"; }

# Validate a profile name: alphanumeric, hyphens, underscores only.
_validate_profile_name() { _validate_name "profile" "$1"; }

# Return 0 if a section's flags should be included given the current
# command mode and backend.
#
# Matching rules:
#   common            -> always include
#   run / serve       -> matching mode, or any mode when mode is empty
#   mlx / llama.cpp   -> matching backend, or any backend when backend is empty
#   mlx.run etc.      -> both dimensions must match; empty selectors widen
#                        the match instead of narrowing it
#
# Callers intentionally pass empty mode/backend when they want an unscoped read
# of the file (for example, 'profile show'), so empty selector values act like
# wildcards here.
_section_matches() {
  local section="$1"
  local mode="$2"
  local backend="$3"

  case "$section" in
    common)
      return 0
      ;;
    run|serve)
      # Command-only section: include if mode is empty (unscoped) or matches.
      [[ -z "$mode" || "$section" == "$mode" ]]
      ;;
    mlx|llama.cpp)
      # Backend-only section: include if backend is empty (unscoped) or matches.
      [[ -z "$backend" || "$section" == "$backend" ]]
      ;;
    mlx.run|mlx.serve|llama.cpp.run|llama.cpp.serve)
      # Backend+command section: both must match (or be empty).
      # %.*: shortest suffix strip → "llama.cpp.run" → "llama.cpp"
      # ##*.: greedy prefix strip → "llama.cpp.run" → "run"
      local sec_backend="${section%.*}"
      local sec_mode="${section##*.}"
      [[ -z "$backend" || "$sec_backend" == "$backend" ]] && \
        [[ -z "$mode" || "$sec_mode" == "$mode" ]]
      ;;
    *)
      # Unknown section: skip silently for forward compatibility.
      return 1
      ;;
  esac
}

_strip_profile_line_comment() {
  local line="$1"

  line="${line#"${line%%[![:space:]]*}"}"
  [[ -z "$line" ]] && return 0
  [[ "$line" == '#'* ]] && return 0

  case "$line" in
    *[[:space:]]#*)
      line="${line%%[[:space:]]#*}"
      ;;
  esac

  _trim_trailing_whitespace "$line"
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
    echo "Usage: $SCRIPT_NAME profile <NAME> <MODEL_SPEC> [-- <flags...>]" >&2
    echo "       $SCRIPT_NAME profile <NAME> <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]" >&2
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
    if [[ "$1" != "--" ]]; then
      die "expected '-- <flags...>', got: $1"
    fi
    shift
    extra_args=("$@")
  fi

  local profiles_dir
  profiles_dir="$(_profiles_dir)"
  mkdir -p "$profiles_dir"

  local path
  path="$(profile_path "$name")"

  if [[ ${#extra_args[@]} -gt 0 ]]; then
    _write_profile_file "$path" "$model_spec" "$template_content" "${extra_args[@]}"
  else
    _write_profile_file "$path" "$model_spec" "$template_content"
  fi
  echo "Profile '${name}' saved."
}

_cmd_profile_copy() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME copy <SOURCE> <DEST>" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local src="$1"
  local dst="$2"

  _validate_profile_name "$src"
  _validate_profile_name "$dst"

  local src_path dst_path
  src_path="$(profile_path "$src")"
  dst_path="$(profile_path "$dst")"

  [[ -f "$src_path" ]] || die "source profile '${src}' not found"
  [[ ! -f "$dst_path" ]] || die "destination profile '${dst}' already exists; remove it first"

  cp "$src_path" "$dst_path"
  echo "Profile '${src}' copied to '${dst}'."
}

_cmd_template_set() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME template <TEMPLATE> [<MODEL_SPEC>] [-- <flags...>]" >&2
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
    if [[ "$1" != "--" ]]; then
      die "expected '-- <flags...>', got: $1"
    fi
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

_cmd_template_copy() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $SCRIPT_NAME copy <SOURCE> <DEST>" >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local src="$1"
  local dst="$2"

  _validate_template_name "$src"
  _validate_template_name "$dst"

  local src_content
  src_content="$(_get_template_content "$src")"

  local templates_dir
  templates_dir="$(_templates_dir)"
  mkdir -p "$templates_dir"

  local dst_path
  dst_path="$(_template_path "$dst")"
  [[ ! -f "$dst_path" ]] || die "destination template '${dst}' already exists; remove it first"

  printf '%s
' "$src_content" > "$dst_path"
  echo "Template '${src}' copied to '${dst}'."
}

cmd_copy() {
  if [[ $# -lt 2 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_copy_usage >&2
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local src="$1"
  local src_profile_path src_template_path
  src_profile_path="$(profile_path "$src")"
  src_template_path="$(_template_path "$src")"

  local profile_exists=0
  local template_exists=0

  [[ -f "$src_profile_path" ]] && profile_exists=1
  if [[ -f "$src_template_path" ]] || _get_builtin_template_content "$src" >/dev/null 2>&1; then
    template_exists=1
  fi

  if [[ $profile_exists -eq 1 && $template_exists -eq 1 ]]; then
    die "source '${src}' is ambiguous; matches both a profile and a template"
  fi

  if [[ $profile_exists -eq 1 ]]; then
    _cmd_profile_copy "$@"
    return
  fi

  if [[ $template_exists -eq 1 ]]; then
    _cmd_template_copy "$@"
    return
  fi

  die "source '${src}' not found as a profile or template"
}
