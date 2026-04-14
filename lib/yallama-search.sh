# Search and browse helpers for yallama.

cmd_search_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME search <QUERY> [--sort <by>] [--limit <n>] [--quants] [--quiet] [--json]

Arguments:
  QUERY         Search term (e.g. "gemma", "qwen", "llama")

Searches HuggingFace for GGUF models compatible with llama.cpp.

Options:
  --sort <by>   Sort order: trending (default), downloads, likes, newest.
  --limit <n>   Maximum number of results. Defaults to 20.
  --quants      Also show available quant variants per model.
                With --quiet: prints one MODEL:QUANT per line.
                With --json: adds a quants array field per model.
  --quiet       Print only model identifiers, one per line.
  --json        Output as a JSON array with name, downloads, and likes fields.
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
_jq_quants_def='def quant_rank: if test("^F32$") then -32 elif test("^(BF16|F16)$") then -16 elif test("^(?:[A-Z]{2}[-_])?I?Q[0-9]+") then (capture("^(?:[A-Z]{2}[-_])?I?Q(?<n>[0-9]+)") | .n | tonumber | -.) else 0 end; def quants: [.siblings[]? | select(.rfilename | test("[.]gguf$")) | .rfilename | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "") | capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q] | unique | sort_by(quant_rank); def default_quant: [.siblings[]? | select(.rfilename | test("[.]gguf$")) | .rfilename] as $files | ((([$files[] | select(test("Q4_K_M[.-]"; "i"))] | sort | .[0]) // ([$files[] | select(test("Q4_0[.-]"; "i"))] | sort | .[0]) // ($files | sort | .[0])) as $f | if $f != null then (($f | split("/") | last | gsub("[.]gguf$"; "") | gsub("-[0-9]+-of-[0-9]+$"; "")) as $stem | (($stem | capture("[-._](?<q>(?:[A-Z]{2}[-_])?(?:I?Q[0-9]+(?:_[A-Z0-9]+)*|F16|BF16|F32))$")? | .q) // $stem)) else null end);'

cmd_search() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_search_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local query="$1"
  shift

  local sort_by="trending"
  local limit=20
  local quants="false"
  local quiet="false"
  local json="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sort)    sort_by="${2:-}"; shift 2 ;;
      --limit)   limit="${2:-}"; shift 2 ;;
      --quants)  quants="true"; shift ;;
      --quiet)   quiet="true"; shift ;;
      --json)    json="true"; shift ;;
      -h|--help) cmd_search_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_search_usage >&2; return 1 ;;
    esac
  done

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

  # library=gguf: HF API filter that limits results to repos tagged as GGUF format.
  # full=true: include sibling (file list) data needed to extract quant names.
  local url="https://huggingface.co/api/models?search=${encoded_query}&library=gguf&sort=${api_sort}&direction=-1&limit=${limit}&full=true"

  local results
  results="$(curl -fsSL \
    --connect-timeout 15 \
    --max-time 30 \
    # ${auth_header[@]+"${auth_header[@]}"}: safely expand an array that might
    # be empty under 'set -u'. If auth_header has no elements, this expands to
    # nothing instead of triggering an "unbound variable" error.
    "${auth_header[@]+"${auth_header[@]}"}" \
    -H "User-Agent: ${SCRIPT_NAME}" \
    "$url")"

  local count
  count="$(printf '%s' "$results" | jq 'length')"

  if [[ "$count" -eq 0 ]]; then
    if [[ "$json" == "true" ]]; then
      echo "[]"
    else
      echo "No models found for: $query"
    fi
    return 0
  fi

  if [[ "$json" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq "${_jq_quants_def}"'
        [.[] | select(quants | length > 0) | {name: .modelId, downloads: .downloads, likes: .likes, quants: quants, default_quant: default_quant}]'
    else
      printf '%s' "$results" | jq "${_jq_quants_def}"'
        [.[] | select(quants | length > 0) | {name: .modelId, downloads: .downloads, likes: .likes}]'
    fi
  elif [[ "$quiet" == "true" ]]; then
    if [[ "$quants" == "true" ]]; then
      printf '%s' "$results" | jq -r "${_jq_quants_def}"'
        .[] | select(quants | length > 0) | .modelId as $m | quants[] | $m + ":" + .'
    else
      printf '%s' "$results" | jq -r "${_jq_quants_def}"'
        .[] | select(quants | length > 0) | .modelId'
    fi
  else
    printf '%-60s  %10s  %s\n' 'MODEL' 'DOWNLOADS' 'LIKES'
    printf '%-60s  %10s  %s\n' '-----' '---------' '-----'
    if [[ "$quants" == "true" ]]; then
      # @tsv: jq formatter that joins array elements with tab characters.
      # Paired with IFS=$'\t' in the read loop below, this provides reliable
      # field splitting even when values contain spaces.
      printf '%s' "$results" \
        | jq -r "${_jq_quants_def}"'
            .[] | select(quants | length > 0) | [.modelId, (.downloads // 0 | tostring), (.likes // 0 | tostring), (default_quant as $dq | quants | map(if . == $dq then "*" + . else . end) | join(" "))] | @tsv' \
        | while IFS=$'\t' read -r name downloads likes qtags; do
            printf '%-60s  %10s  %s\n' "$name" "$downloads" "$likes"
            [[ -n "$qtags" ]] && printf '  %s\n' "$qtags"
          done
    else
      printf '%s' "$results" \
        | jq -r "${_jq_quants_def}"'
            .[] | select(quants | length > 0) | [.modelId, (.downloads // 0 | tostring), (.likes // 0 | tostring)] | @tsv' \
        | while IFS=$'\t' read -r name downloads likes; do
            printf '%-60s  %10s  %s\n' "$name" "$downloads" "$likes"
          done
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
