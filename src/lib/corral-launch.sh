# Launch supported third-party coding harnesses against a running corral server.
# shellcheck shell=bash

CORRAL_LAUNCH_PROVIDER_ID="corral-launch"

_get_builtin_launch_template_content() {
  local name="$1"
  # BEGIN_BUILTIN_LAUNCH_TEMPLATES
  local template_dir
  template_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../launch-templates"
  if [[ -f "${template_dir}/${name}.tmpl" ]]; then
    cat "${template_dir}/${name}.tmpl"
    return 0
  fi
  return 1
  # END_BUILTIN_LAUNCH_TEMPLATES
}

_render_launch_template() {
  local template_name="$1"
  local provider_id="$2"
  local endpoint="$3"
  local model="$4"
  local template

  template="$(_get_builtin_launch_template_content "$template_name")" || \
    die "unknown launch template '${template_name}'"

  template="${template//__CORRAL_PROVIDER_ID__/$provider_id}"
  template="${template//__CORRAL_ENDPOINT__/$endpoint}"
  template="${template//__CORRAL_MODEL__/$model}"
  printf '%s\n' "$template"
}

_launch_timestamp() {
  date -u +"%Y%m%dT%H%M%SZ"
}

_ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

_write_text_file_with_backup() {
  local path="$1"
  local content="$2"
  local backup_existing_match="${3:-0}"
  local current=""

  REPLY_FILE_UPDATED="0"
  REPLY_FILE_BACKUP=""

  if [[ -f "$path" ]]; then
    current="$(cat "$path")"
  fi

  if [[ "$current" == "$content" ]]; then
    if [[ "$backup_existing_match" == "1" && -f "$path" ]] && ! compgen -G "${path}.bak.*" > /dev/null; then
      REPLY_FILE_BACKUP="${path}.bak.${CORRAL_LAUNCH_RUN_TIMESTAMP}"
      cp "$path" "$REPLY_FILE_BACKUP"
    fi
    return 0
  fi

  _ensure_parent_dir "$path"

  if [[ -f "$path" ]]; then
    REPLY_FILE_BACKUP="${path}.bak.${CORRAL_LAUNCH_RUN_TIMESTAMP}"
    cp "$path" "$REPLY_FILE_BACKUP"
  fi

  local tmp_file
  tmp_file="$(mktemp "$(dirname "$path")/.corral-launch.$(basename "$path").XXXXXX")"
  printf '%s\n' "$content" > "$tmp_file"
  mv "$tmp_file" "$path"
  REPLY_FILE_UPDATED="1"
}

_strip_jsonc() {
  awk '
    {
      text = text $0 ORS
    }

    END {
      out = ""
      i = 1
      in_string = 0
      escape = 0
      while (i <= length(text)) {
        ch = substr(text, i, 1)

        if (in_string) {
          out = out ch
          if (escape) {
            escape = 0
          } else if (ch == "\\") {
            escape = 1
          } else if (ch == "\"") {
            in_string = 0
          }
          i += 1
          continue
        }

        if (ch == "\"") {
          in_string = 1
          out = out ch
          i += 1
          continue
        }

        if (ch == "/" && i < length(text)) {
          nxt = substr(text, i + 1, 1)
          if (nxt == "/") {
            i += 2
            while (i <= length(text)) {
              line_ch = substr(text, i, 1)
              if (line_ch == "\r" || line_ch == "\n") {
                break
              }
              i += 1
            }
            continue
          }
          if (nxt == "*") {
            i += 2
            while (i < length(text) && !(substr(text, i, 1) == "*" && substr(text, i + 1, 1) == "/")) {
              i += 1
            }
            i += 2
            continue
          }
        }

        out = out ch
        i += 1
      }

      text = out
      out = ""
      i = 1
      in_string = 0
      escape = 0
      while (i <= length(text)) {
        ch = substr(text, i, 1)

        if (in_string) {
          out = out ch
          if (escape) {
            escape = 0
          } else if (ch == "\\") {
            escape = 1
          } else if (ch == "\"") {
            in_string = 0
          }
          i += 1
          continue
        }

        if (ch == "\"") {
          in_string = 1
          out = out ch
          i += 1
          continue
        }

        if (ch == ",") {
          j = i + 1
          while (j <= length(text) && substr(text, j, 1) ~ /[[:space:]]/) {
            j += 1
          }
          if (j <= length(text)) {
            nxt = substr(text, j, 1)
            if (nxt == "]" || nxt == "}") {
              i += 1
              continue
            }
          }
        }

        out = out ch
        i += 1
      }

      printf "%s", out
    }
  '
}

_normalize_json_for_merge() {
  local json_text="$1"
  local jsonc_mode="${2:-0}"
  local merge_mode="${3:-default}"
  local jq_filter='.'

  if [[ -z "${json_text//[$' \t\r\n']/}" ]]; then
    printf '{}\n'
    return 0
  fi

  if [[ "$jsonc_mode" == "1" ]]; then
    json_text="$(printf '%s' "$json_text" | _strip_jsonc)"
    if [[ -z "${json_text//[$' \t\r\n']/}" ]]; then
      printf '{}\n'
      return 0
    fi
  fi

  case "$merge_mode" in
    pi-models)
      # shellcheck disable=SC2016  # jq program is intentionally single-quoted.
      jq_filter='def is_provider_entry: type == "object" and (has("api") or has("baseUrl") or has("models"));
        if type != "object" then
          {}
        elif has("providers") then
          if (.providers | type) != "object" then
            error("existing models.json has invalid '\''providers'\'' structure")
          else
            .
          end
        else
          reduce keys_unsorted[] as $key
            (. + {providers: {}};
              if (.[$key] | is_provider_entry) then
                .providers[$key] = .[$key] | del(.[$key])
              else
                .
              end)
        end'
      ;;
  esac

  printf '%s' "$json_text" | jq "$jq_filter"
}

_render_merged_json_file() {
  local path="$1"
  local patch_text="$2"
  local jsonc_mode="${3:-0}"
  local merge_mode="${4:-default}"
  local current_text=""
  local current_json
  local current_canonical
  local merged_json
  local merged_canonical

  if [[ -f "$path" ]]; then
    current_text="$(cat "$path")"
  fi

  current_json="$(_normalize_json_for_merge "$current_text" "$jsonc_mode" "$merge_mode")"
  merged_json="$(jq -s '
    if (.[0] | type) == "object" and (.[1] | type) == "object" then
      .[0] * .[1]
    else
      .[1]
    end
  ' <(printf '%s\n' "$current_json") <(printf '%s\n' "$patch_text"))"

  current_canonical="$(printf '%s\n' "$current_json" | jq -cS '.')"
  merged_canonical="$(printf '%s\n' "$merged_json" | jq -cS '.')"

  if [[ -f "$path" && "$current_canonical" == "$merged_canonical" ]]; then
    if [[ -n "$current_text" && "$current_text" != *$'\n' ]]; then
      printf '%s\n' "$current_text"
    else
      printf '%s' "$current_text"
    fi
    return 0
  fi

  printf '%s\n' "$merged_json"
}

_report_file_update() {
  local path="$1"
  if [[ "$REPLY_FILE_UPDATED" == "1" ]]; then
    if [[ -n "$REPLY_FILE_BACKUP" ]]; then
      printf 'Backed up %s to %s\n' "$path" "$REPLY_FILE_BACKUP"
    fi
    printf 'Updated %s\n' "$path"
  else
    printf 'Config already matched %s\n' "$path"
  fi
}

_launch_is_server_process() {
  case "$1" in
    llama-server|mlx_lm.server) return 0 ;;
    *) return 1 ;;
  esac
}

_launch_tool_supports_process() {
  local tool="$1"
  local process_name="$2"

  if ! _launch_is_server_process "$process_name"; then
    return 1
  fi

  case "$tool" in
    pi|opencode)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_launch_resolve_target() {
  local tool="$1"
  local requested_port="${2:-}"
  local rows eligible_rows=""

  rows="$(_emit_runtime_process_rows)"

  while IFS=$'\t' read -r pid process_name port model; do
    [[ -n "$pid" ]] || continue
    if ! _launch_tool_supports_process "$tool" "$process_name"; then
      continue
    fi
    if [[ -n "$requested_port" && "$port" != "$requested_port" ]]; then
      continue
    fi
    eligible_rows+="${pid}"$'\t'"${process_name}"$'\t'"${port}"$'\t'"${model}"$'\n'
  done <<< "$rows"

  if [[ -z "$eligible_rows" ]]; then
    die "no compatible corral server found. Start one with '$SCRIPT_NAME serve ...' and use '$SCRIPT_NAME ps' to inspect running servers."
  fi

  local row_count
  row_count="$(printf '%s' "$eligible_rows" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$row_count" -gt 1 ]]; then
    printf 'Multiple compatible corral servers are running; choose one with --port:\n' >&2
    _print_tsv_table 'llll' $'PID\tPROCESS\tPORT\tMODEL' <<< "$eligible_rows" >&2
    return 1
  fi

  IFS=$'\t' read -r _ REPLY_LAUNCH_PROCESS REPLY_LAUNCH_PORT REPLY_LAUNCH_MODEL <<< "$eligible_rows"
  REPLY_LAUNCH_ENDPOINT="http://127.0.0.1:${REPLY_LAUNCH_PORT}/v1"
}

_pi_agent_dir() {
  printf '%s\n' "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
}

_opencode_config_path() {
  local config_root="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if [[ -f "${config_root}/opencode.jsonc" ]]; then
    printf '%s\n' "${config_root}/opencode.jsonc"
  else
    printf '%s\n' "${config_root}/opencode.json"
  fi
}

_configure_pi_launch() {
  local endpoint="$1"
  local model="$2"
  local provider_id="$3"
  local agent_dir settings_path models_path settings_patch models_patch rendered

  agent_dir="$(_pi_agent_dir)"
  settings_path="${agent_dir}/settings.json"
  models_path="${agent_dir}/models.json"

  settings_patch="$(_render_launch_template "pi-settings" "$provider_id" "$endpoint" "$model")"
  rendered="$(_render_merged_json_file "$settings_path" "$settings_patch")"
  _write_text_file_with_backup "$settings_path" "$rendered" 1
  _report_file_update "$settings_path"

  models_patch="$(_render_launch_template "pi-models" "$provider_id" "$endpoint" "$model")"
  rendered="$(_render_merged_json_file "$models_path" "$models_patch" 0 "pi-models")"
  _write_text_file_with_backup "$models_path" "$rendered" 1
  _report_file_update "$models_path"
}

_configure_opencode_launch() {
  local endpoint="$1"
  local model="$2"
  local provider_id="$3"
  local config_path patch rendered jsonc_mode="0"

  config_path="$(_opencode_config_path)"
  [[ "$config_path" == *.jsonc ]] && jsonc_mode="1"

  patch="$(_render_launch_template "opencode" "$provider_id" "$endpoint" "$model")"
  rendered="$(_render_merged_json_file "$config_path" "$patch" "$jsonc_mode")"
  _write_text_file_with_backup "$config_path" "$rendered"
  _report_file_update "$config_path"
}

cmd_launch_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME launch [--port <port>] <pi|opencode> [-- <extra args...>]

Arguments:
  pi|opencode  Supported coding harness to configure and launch.

Options:
  --port <port>      Use a specific running corral server when multiple are active.

Corral inspects the selected running server, updates the harness configuration
to point at that server's OpenAI-compatible endpoint and model, backs up the
existing config next to the original when it changes, and then launches the
harness.

Notes:
  - pi and opencode work with llama-server and mlx_lm.server.

Examples:
  $SCRIPT_NAME launch pi
  $SCRIPT_NAME launch --port 8082 opencode
EOF
}

cmd_launch() {
  if [[ $# -eq 0 ]]; then
    cmd_launch_usage
    return 1
  fi

  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_launch_usage
    return 0
  fi

  local requested_port=""
  local tool=""
  local extra_args=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port)
        requested_port="${2:-}"
        [[ -n "$requested_port" ]] || die "missing value for --port"
        [[ "$requested_port" =~ ^[0-9]+$ ]] || die "invalid port '${requested_port}'"
        shift 2
        ;;
      --)
        shift
        extra_args=("$@")
        break
        ;;
      -h|--help)
        cmd_launch_usage
        return 0
        ;;
      -*)
        echo "Unknown argument: $1" >&2
        cmd_launch_usage >&2
        return 1
        ;;
      *)
        if [[ -n "$tool" ]]; then
          echo "Unknown argument: $1" >&2
          cmd_launch_usage >&2
          return 1
        fi
        tool="$1"
        shift
        ;;
    esac
  done

  case "$tool" in
    pi|opencode)
      ;;
    *)
      die "unsupported launch target '${tool}'. Expected one of: pi, opencode"
      ;;
  esac

  require_cmds date "$tool"
  CORRAL_LAUNCH_RUN_TIMESTAMP="$(_launch_timestamp)"

  if ! _launch_resolve_target "$tool" "$requested_port"; then
    return 1
  fi

  printf 'Using corral server on port %s (%s, model %s)\n' \
    "$REPLY_LAUNCH_PORT" "$REPLY_LAUNCH_PROCESS" "$REPLY_LAUNCH_MODEL"

  case "$tool" in
    pi)
      require_cmds jq
      _configure_pi_launch "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL" "$CORRAL_LAUNCH_PROVIDER_ID"
      ;;
    opencode)
      require_cmds jq
      _configure_opencode_launch "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL" "$CORRAL_LAUNCH_PROVIDER_ID"
      ;;
  esac

  printf 'Launching %s against %s (model: %s)\n' \
    "$tool" "$REPLY_LAUNCH_ENDPOINT" "$REPLY_LAUNCH_MODEL"

  case "$tool" in
    pi)
      exec pi "${extra_args[@]+"${extra_args[@]}"}"
      ;;
    opencode)
      exec opencode "${extra_args[@]+"${extra_args[@]}"}"
      ;;
  esac
}
