# Search and browse helpers for corral.
# shellcheck shell=bash

cmd_search_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME search [--backend <mlx|llama.cpp>] <QUERY> [--sort <by>] [--limit <n>] [--quants] [--quiet] [--json]

Arguments:
  QUERY         Search term (e.g. "gemma", "qwen", "llama")

Searches HuggingFace for backend-compatible models.
On macOS Apple Silicon, both GGUF (llama.cpp) and MLX-compatible models are
returned by default. Use --backend to restrict to a single type.
Results include a TYPE column when showing mixed backend results.

Options:
  --backend <backend>
                Backend search mode: llama.cpp (GGUF-focused) or mlx (MLX-friendly models).
                If omitted on macOS Apple Silicon, searches both types.
  --sort <by>   Sort order: trending (default), downloads, likes, newest.
  --limit <n>   Maximum number of results. Defaults to 20.
  --quants      llama.cpp only. Also show available quant variants per model.
                With --quiet: prints one MODEL:QUANT per line when quants exist,
                otherwise prints MODEL.
                With --json: adds a quants array field per model.
  --quiet       Print only model identifiers, one per line.
  --json        Output as a JSON array with name, type, downloads, and likes fields.
EOF
}

# Inline jq helper function definitions reused across all jq invocations in cmd_search.
#
#   quant_rank    assign a numeric sort weight so higher-precision types sort first:
#                   F32 → -32, F16/BF16 → -16, QN → -N, unknown → 0.
#   quants        extract all unique quant tags from a model's .siblings[] filenames
#                 using the same separator + pattern logic as extract_quant_from_filename.
#   default_quant select the 'best default' GGUF: prefer Q4_K_M, then Q4_0,
#                 then the lexicographically first GGUF found.
# shellcheck disable=SC2016  # $ signs are jq regex anchors, not bash variables
_jq_quants_def='def quant_rank: if test("^F32$") then -32 elif test("^(BF16|F16)$") then -16 elif test("^(?:[A-Z]{2}[-_])?I?Q[0-9]+") then (capture("^(?:[A-Z]{2}[-_])?I?Q(?<n>[0-9]+)") | .n | tonumber | -.) else 0 end; def gguf_files: [.siblings[]? | .rfilename | select(type == "string" and test("[.]gguf$"; "i"))]; def has_gguf_tag: (((.tags // []) | map(ascii_downcase) | index("gguf")) != null); def has_gguf: ((gguf_files | length > 0) or ((.library_name // "" | ascii_downcase) == "gguf") or has_gguf_tag); def quants: [gguf_files[] | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "") | (capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q) | select(type == "string")] | unique | sort_by(quant_rank); def default_quant: gguf_files as $files | ((([$files[] | select(test("Q4_K_M[.-]"; "i"))] | sort | .[0]) // ([$files[] | select(test("Q4_0[.-]"; "i"))] | sort | .[0]) // ($files | sort | .[0])) as $f | if $f != null then (($f | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "")) as $stem | (($stem | capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q) // $stem)) else null end);'
_jq_mlx_def='def has_mlx: (((.modelId // "") | startswith("mlx-community/")) or (((.tags // []) | map(ascii_downcase) | index("mlx")) != null) or ((.library_name // "" | ascii_downcase) == "mlx"));'

# Combined model-type classifier: "llama.cpp", "mlx", or "both".
# shellcheck disable=SC2016  # $ signs are jq expressions, not bash variables
_jq_combined_def="${_jq_quants_def}${_jq_mlx_def}"'def model_type: if (has_gguf and has_mlx) then "both" elif has_gguf then "llama.cpp" elif has_mlx then "mlx" else "unknown" end;'

cmd_search() {
  if [[ $# -eq 0 ]]; then
    cmd_search_usage
    return 1
  fi

  local BACKEND_FLAG=""
  local query=""
  local sort_by="trending"
  local limit=20
  local quants="false"
  local quiet="false"
  local json="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND_FLAG="${2:-}"; shift 2 ;;
      --sort)    sort_by="${2:-}"; shift 2 ;;
      --limit)   limit="${2:-}"; shift 2 ;;
      --quants)  quants="true"; shift ;;
      --quiet)   quiet="true"; shift ;;
      --json)    json="true"; shift ;;
      -h|--help) cmd_search_usage; return 0 ;;
      *)
        if [[ -z "$query" ]]; then
          query="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          cmd_search_usage >&2
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "$query" ]]; then
    cmd_search_usage >&2
    return 1
  fi

  # Determine effective backend and whether to run a combined search.
  # Combined mode: no explicit backend (flag or env) AND on Apple Silicon.
  local BACKEND=""
  local COMBINED_SEARCH="false"
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  elif _is_mlx_platform; then
    COMBINED_SEARCH="true"
  else
    BACKEND="llama.cpp"
  fi

  if [[ "$COMBINED_SEARCH" == "false" && "$BACKEND" == "mlx" && "$quants" == "true" ]]; then
    echo "Warning: --quants is only supported for llama.cpp/GGUF search; ignoring for MLX." >&2
    quants="false"
  fi

  [[ "$limit" =~ ^[0-9]+$ ]] || die "invalid --limit value '${limit}': must be a positive integer"
  (( limit > 0 )) || die "invalid --limit value '${limit}': must be greater than zero"

  local api_sort
  case "$sort_by" in
    trending)  api_sort="trendingScore" ;;
    downloads) api_sort="downloads" ;;
    likes)     api_sort="likes" ;;
    newest)    api_sort="lastModified" ;;
    *)         die "unknown sort value '${sort_by}': must be trending, downloads, likes, or newest" ;;
  esac

  require_cmds curl jq

  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  # URL-encode the query string using jq's built-in @uri formatter, avoiding
  # a dependency on python, perl, or other external URL-encoding utilities.
  local encoded_query
  encoded_query="$(printf '%s' "$query" | jq -Rr @uri)"

  # full=true: include sibling (file list) data needed for quant extraction and filtering.
  # Fetch more than the requested limit so optional quant details still have rich metadata.
  local fetch_limit=$(( limit * 5 ))
  (( fetch_limit < 200 )) && fetch_limit=200
  (( fetch_limit > 500 )) && fetch_limit=500
  local url="https://huggingface.co/api/models?search=${encoded_query}&sort=${api_sort}&direction=-1&limit=${fetch_limit}&full=true"
  if [[ "$COMBINED_SEARCH" == "false" && "$BACKEND" == "llama.cpp" ]]; then
    url+="&library=gguf"
  fi

  # ${auth_header[@]+"${auth_header[@]}"}: safely expand an array that might
  # be empty under 'set -u'. If auth_header has no elements, this expands to
  # nothing instead of triggering an "unbound variable" error.
  # NOTE: this comment intentionally lives outside the $() block — bash
  # backslash-continuation lines cannot contain inline comments.
  local results
  results="$(curl -fsSL \
    --connect-timeout 15 \
    --max-time 30 \
    "${auth_header[@]+"${auth_header[@]}"}" \
    -H "User-Agent: ${SCRIPT_NAME}" \
    "$url")"

  local count
  if [[ "$COMBINED_SEARCH" == "true" ]]; then
    count="$(printf '%s' "$results" | jq "${_jq_combined_def}"'
      [.[] | select(has_gguf or has_mlx)] | length')"
  elif [[ "$BACKEND" == "mlx" ]]; then
    count="$(printf '%s' "$results" | jq "${_jq_mlx_def}"'
      [.[] | select(has_mlx)] | length')"
  else
    count="$(printf '%s' "$results" | jq "${_jq_quants_def}"'
      [.[] | select(has_gguf)] | length')"
  fi

  if [[ "$count" -eq 0 ]]; then
    if [[ "$json" == "true" ]]; then
      echo "[]"
    else
      echo "No models found for: $query"
    fi
    return 0
  fi

  # ── Combined search output ────────────────────────────────────────────────
  if [[ "$COMBINED_SEARCH" == "true" ]]; then
    if [[ "$json" == "true" ]]; then
      if [[ "$quants" == "true" ]]; then
        printf '%s' "$results" | jq "${_jq_combined_def}"'
          [.[] | select(has_gguf or has_mlx) | {name: .modelId, type: model_type, downloads: .downloads, likes: .likes, quants: (if has_gguf then quants else [] end), default_quant: (if has_gguf then default_quant else null end)}][0:'"${limit}"']'
      else
        printf '%s' "$results" | jq "${_jq_combined_def}"'
          [.[] | select(has_gguf or has_mlx) | {name: .modelId, type: model_type, downloads: .downloads, likes: .likes}][0:'"${limit}"']'
      fi
    elif [[ "$quiet" == "true" ]]; then
      printf '%s' "$results" | jq -r "${_jq_combined_def}"'
        [.[] | select(has_gguf or has_mlx)][0:'"${limit}"'][] | .modelId'
    elif [[ "$quants" == "true" ]]; then
      printf '%s' "$results" \
        | jq -r "${_jq_combined_def}"'
            [.[] | select(has_gguf or has_mlx)][0:'"${limit}"'][] |
            [.modelId, model_type, (.downloads // 0 | tostring), (.likes // 0 | tostring),
             (if has_gguf then (default_quant as $dq | quants | map(if . == $dq then "*" + . else . end) | join(" ")) else "-" end)] | @tsv' \
        | _print_tsv_table 'llrrl' $'MODEL\tTYPE\tDOWNLOADS\tLIKES\tQUANTS'
    else
      printf '%s' "$results" \
        | jq -r "${_jq_combined_def}"'
              [.[] | select(has_gguf or has_mlx)][0:'"${limit}"'][] |
              [.modelId, model_type, (.downloads // 0 | tostring), (.likes // 0 | tostring)] | @tsv' \
        | _print_tsv_table 'llrr' $'MODEL\tTYPE\tDOWNLOADS\tLIKES'
    fi
    return 0
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    if [[ "$json" == "true" ]]; then
      printf '%s' "$results" | jq "${_jq_mlx_def}"'
        [.[] | select(has_mlx) | {name: .modelId, downloads: .downloads, likes: .likes}][0:'"${limit}"']'
    elif [[ "$quiet" == "true" ]]; then
      printf '%s' "$results" | jq -r "${_jq_mlx_def}"'
        [.[] | select(has_mlx)][0:'"${limit}"'][] | .modelId'
    else
      printf '%s' "$results" \
        | jq -r "${_jq_mlx_def}"'
              [.[] | select(has_mlx)][0:'"${limit}"'][] | [.modelId, (.downloads // 0 | tostring), (.likes // 0 | tostring)] | @tsv' \
        | _print_tsv_table 'lrr' $'MODEL\tDOWNLOADS\tLIKES'
    fi
    return 0
  fi

  if [[ "$json" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq "${_jq_quants_def}"'
        [.[] | select(has_gguf) | {name: .modelId, downloads: .downloads, likes: .likes, quants: quants, default_quant: default_quant}][0:'"${limit}"']'
    else
      printf '%s' "$results" | jq "${_jq_quants_def}"'
        [.[] | select(has_gguf) | {name: .modelId, downloads: .downloads, likes: .likes}][0:'"${limit}"']'
    fi
  elif [[ "$quiet" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq -r "${_jq_quants_def}"'
        [.[] | select(has_gguf)][0:'"${limit}"'][] | .modelId as $m | (quants | if length > 0 then .[] | ($m + ":" + .) else $m end)'
    else
      printf '%s' "$results" | jq -r "${_jq_quants_def}"'
        [.[] | select(has_gguf)][0:'"${limit}"'][] | .modelId'
    fi
  else
    if [[ "$quants" == "true" ]]; then
      # @tsv: jq formatter that joins array elements with tab characters.
      # Paired with IFS=$'\t' in the read loop below, this provides reliable
      # field splitting even when values contain spaces.
      printf '%s' "$results" \
        | jq -r "${_jq_quants_def}"'
            [.[] | select(has_gguf)][0:'"${limit}"'][] | [.modelId, (.downloads // 0 | tostring), (.likes // 0 | tostring), (default_quant as $dq | quants | map(if . == $dq then "*" + . else . end) | join(" "))] | @tsv' \
        | _print_tsv_table 'lrrl' $'MODEL\tDOWNLOADS\tLIKES\tQUANTS'
    else
      printf '%s' "$results" \
        | jq -r "${_jq_quants_def}"'
              [.[] | select(has_gguf)][0:'"${limit}"'][] | [.modelId, (.downloads // 0 | tostring), (.likes // 0 | tostring)] | @tsv' \
        | _print_tsv_table 'lrr' $'MODEL\tDOWNLOADS\tLIKES'
    fi
  fi
}

cmd_browse_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME browse <MODEL_NAME> [--print]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF

Opens the HuggingFace page for a model in your browser.

Options:
  --print       Print the URL instead of opening a browser.
EOF
}

cmd_browse() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_browse_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local model_spec="$1"
  local print_only="false"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --print)   print_only="true"; shift ;;
      -h|--help) cmd_browse_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_browse_usage >&2; return 1 ;;
    esac
  done

  _parse_model_spec "$model_spec"
  local model_name="$REPLY_MODEL"
  local url="https://huggingface.co/${model_name}"

  if [[ "$print_only" == "true" ]]; then
    echo "$url"
    return 0
  fi

  # Platform-specific "open URL in default browser" command.
  # macOS provides 'open', most Linux desktops provide 'xdg-open'.
  local open_cmd=""
  case "$(uname -s)" in
    Darwin) open_cmd="open" ;;
    Linux)  open_cmd="xdg-open" ;;
  esac

  if [[ -n "$open_cmd" ]] && command -v "$open_cmd" >/dev/null 2>&1; then
    "$open_cmd" "$url"
  else
    echo "$url"
  fi
}
