# Show command for corral.
#
# Unified 'show' command that displays details about a profile, template, or model:
#   - Profiles: shows the profile file content (model + flags)
#   - Templates: shows template content (user-defined or built-in)
#   - Models: fetches metadata from HuggingFace API and displays model info
#
# Resolution logic:
#   1. If --profile is passed → look up in profiles directory
#   2. If --template is passed → look up in templates (user then built-in)
#   3. If --model is passed → fetch from HuggingFace API
#   4. If no flag:
#      - Check if it's a profile name → show profile
#      - Check if it's a template name → show template
#      - Check if it looks like a model (contains '/') → fetch from HF
#      - If collision between profile and template → error with suggestion
#      - Otherwise → error: "not found"
#
# shellcheck shell=bash

cmd_show_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME show [--profile|--template|--model] <NAME>

Shows details about a profile, template, or model.

Arguments:
  NAME          The name of the profile, template, or model to show.

Flags:
  --profile     Treat NAME as a profile (even if it matches a template name).
  --template    Treat NAME as a template (even if it matches a profile name).
  --model       Treat NAME as a HuggingFace model and fetch its details.

If no flag is given, corral tries to resolve the name automatically:
  - If it matches a saved profile, shows the profile.
  - If it matches a template (user or built-in), shows the template.
  - If it contains '/' (looks like a model id), fetches from HuggingFace.
  - If both a profile and template share the same name, use --profile or
    --template to disambiguate.

Model output includes: model ID, author, downloads, likes, tags, pipeline tag,
last modified date, and available quant variants (for GGUF models).

Examples:
  $SCRIPT_NAME show myprofile
  $SCRIPT_NAME show --profile myprofile
  $SCRIPT_NAME show qwen
  $SCRIPT_NAME show --template gemma
  $SCRIPT_NAME show unsloth/gemma-4-26B-A4B-it-GGUF
  $SCRIPT_NAME show --model unsloth/gemma-4-26B-A4B-it-GGUF
EOF
}

cmd_show() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_show_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local kind=""
  local name=""

  # Parse flags first.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)   kind="profile"; shift ;;
      --template)  kind="template"; shift ;;
      --model)     kind="model"; shift ;;
      -h|--help)   cmd_show_usage; return 0 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          cmd_show_usage >&2
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "$name" ]]; then
    echo "Error: missing NAME argument." >&2
    cmd_show_usage >&2
    return 1
  fi

  case "$kind" in
    profile) _cmd_show_profile "$name" ;;
    template) _cmd_show_template "$name" ;;
    model)   _cmd_show_model "$name" ;;
    "")      _cmd_show_resolve "$name" ;;
  esac
}

_cmd_show_profile() {
  local name="$1"
  _validate_profile_name "$name"

  local path
  path="$(profile_path "$name")"
  [[ -f "$path" ]] || die "profile '${name}' not found"

  cat "$path"
}

_cmd_show_template() {
  local name="$1"
  _validate_template_name "$name"

  _get_template_content "$name"
}

_cmd_show_model() {
  local model_spec="$1"

  # Validate it looks like a model id (has a slash).
  if [[ "$model_spec" != */* ]]; then
    die "'${model_spec}' does not look like a HuggingFace model id (expected USER/MODEL format)"
  fi

  parse_model_spec "$model_spec"
  local model_name="$REPLY_MODEL"

  require_cmds curl jq

  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  local metadata
  metadata="$({
    curl -fsSL \
      --connect-timeout 15 \
      --max-time 30 \
      --retry 3 \
      --retry-delay 2 \
      "${auth_header[@]+"${auth_header[@]}"}" \
      -H "User-Agent: ${SCRIPT_NAME}" \
      "https://huggingface.co/api/models/${model_name}"
  } 2>/dev/null)" || die "failed to fetch model details for '${model_name}'"

  # Check if the model exists.
  local error_msg
  error_msg="$(printf '%s' "$metadata" | jq -r '.error // empty' 2>/dev/null || true)"
  if [[ -n "$error_msg" ]]; then
    die "model '${model_name}' not found on HuggingFace: ${error_msg}"
  fi

  # Check if it's a valid JSON response.
  if ! printf '%s' "$metadata" | jq -e '.' >/dev/null 2>&1; then
    die "failed to parse model details for '${model_name}'"
  fi

  _emit_model_details "$metadata"
}

_emit_model_details() {
  local metadata="$1"

  local model_id author downloads likes tags_str pipeline_tag last_modified
  model_id="$(printf '%s' "$metadata" | jq -r '.modelId // "unknown"')"
  author="$(printf '%s' "$metadata" | jq -r '.author // "unknown"')"
  downloads="$(printf '%s' "$metadata" | jq -r '.downloads // 0')"
  likes="$(printf '%s' "$metadata" | jq -r '.likes // 0')"
  tags_str="$(printf '%s' "$metadata" | jq -r '(.tags // []) | join(", ")')"
  pipeline_tag="$(printf '%s' "$metadata" | jq -r '.pipeline_tag // "unknown"')"
  last_modified="$(printf '%s' "$metadata" | jq -r '.lastModified // "unknown"')"

  # Format the date for readability.
  if [[ "$last_modified" != "unknown" ]]; then
    # HF returns ISO 8601 format; convert to a more readable form.
    last_modified="$(date -d "$last_modified" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$last_modified")"
  fi

  # Print header info as key: value pairs.
  printf 'Model: %s\n' "$model_id"
  printf 'Author: %s\n' "$author"
  printf 'Downloads: %d\n' "$(printf '%.0f' "$downloads")"
  printf 'Likes: %d\n' "$likes"
  printf 'Pipeline: %s\n' "$pipeline_tag"
  printf 'Tags: %s\n' "$tags_str"
  printf 'Last Modified: %s\n' "$last_modified"

  echo

  # Check for GGUF quants.
  local has_gguf="false"
  if printf '%s' "$metadata" | jq -e '
      (((.tags // []) | map(ascii_downcase) | index("gguf")) != null) or
      ((.siblings // []) | any(.rfilename?; (. // "" | ascii_downcase | endswith(".gguf"))))
    ' >/dev/null 2>&1; then
    has_gguf="true"
  fi

  if [[ "$has_gguf" == "true" ]]; then
    local quants
    quants="$(printf '%s' "$metadata" | jq -r '
      .siblings // [] |
      map(select(.rfilename | (. // "" | ascii_downcase | endswith(".gguf")))) |
      map(.rfilename) |
      map(gsub("^.*?-"; "")) |          # strip everything before the last dash
      map(gsub("-0000[0-9]+-of-.*$"; "")) |  # strip sharded suffixes
      map(gsub("\\.gguf$"; "")) |        # strip .gguf extension
      unique |
      sort |
      .[]
    ')"

    if [[ -n "$quants" ]]; then
      echo "Available quants:"
      while IFS= read -r quant; do
        [[ -n "$quant" ]] && printf '  %s\n' "$quant"
      done <<< "$quants"
      echo
    fi
  fi
}

_cmd_show_resolve() {
  local name="$1"

  # Check if it looks like a model id (contains '/') before validating.
  # Model IDs have slashes which would fail the generic name validation.
  if [[ "$name" == */* ]]; then
    _cmd_show_model "$name"
    return
  fi

  # Check for profile.
  local profile_path_val
  profile_path_val="$(profile_path "$name")"
  local is_profile="false"
  [[ -f "$profile_path_val" ]] && is_profile="true"

  # Check for template (user-defined first, then built-in).
  local template_path_val
  template_path_val="$(_template_path "$name")"
  local is_user_template="false"
  [[ -f "$template_path_val" ]] && is_user_template="true"

  local is_builtin_template="false"
  if [[ "$is_user_template" != "true" ]]; then
    if _get_builtin_template_content "$name" >/dev/null 2>&1; then
      is_builtin_template="true"
    fi
  fi

  local is_template="false"
  [[ "$is_user_template" == "true" || "$is_builtin_template" == "true" ]] && is_template="true"

  # Handle collision.
  if [[ "$is_profile" == "true" && "$is_template" == "true" ]]; then
    die "ambiguous name '${name}': both a profile and template exist. Use --profile or --template to disambiguate."
  fi

  if [[ "$is_profile" == "true" ]]; then
    _cmd_show_profile "$name"
    return
  fi

  if [[ "$is_template" == "true" ]]; then
    _cmd_show_template "$name"
    return
  fi

  die "'${name}' not found: no matching profile, template, or model"
}
