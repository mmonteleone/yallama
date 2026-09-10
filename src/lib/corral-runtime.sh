# Backend lifecycle and model execution helpers for corral.
#
# Provides:
#   - Private runtime utilities: _clear_macos_quarantine(), _detect_arch(),
#     _github_get(), _get_release_json(), _get_latest_tag(),
#     _delete_hf_model_cache_dirs()
#   - llama.cpp lifecycle: _do_install(), _update_llama(), _uninstall_llama_components()
#   - MLX lifecycle: _do_install_mlx(), _update_mlx(), _uninstall_mlx_components()
#   - Non-fatal variants: _try_install_mlx(), _try_update_mlx() — used by the
#     combined (all-backends) paths; warn and return 0 instead of dying.
#   - Shared model-command prep: _parse_model_command_args(),
#     _resolve_model_command_context()
#   - Model pull: cmd_pull(), _pull_mlx()
#   - Model run: cmd_run(), _run_mlx()
#   - Model serve: cmd_serve(), _serve_mlx()
#   - Backend inference: _infer_model_backend() (GGUF-first for run/serve),
#     _infer_pull_backend() (platform-default for pull)
#   - Maintenance: cmd_prune(), cmd_versions(), cmd_status()
# shellcheck shell=bash

cmd_install_usage() { _cmd_install_usage; }
cmd_install() { _cmd_install "$@"; }
cmd_update_usage() { _cmd_update_usage; }
cmd_update() { _cmd_update "$@"; }
cmd_status_usage() { _cmd_status_usage; }
cmd_status() { _cmd_status "$@"; }
cmd_uninstall_usage() { _cmd_uninstall_usage; }
cmd_uninstall() { _cmd_uninstall "$@"; }
cmd_versions_usage() { _cmd_versions_usage; }
cmd_versions() { _cmd_versions "$@"; }
cmd_prune_usage() { _cmd_prune_usage; }
cmd_prune() { _cmd_prune "$@"; }
cmd_pull_usage() { _cmd_pull_usage; }
cmd_pull() { _cmd_pull "$@"; }
cmd_run_usage() { _cmd_run_usage; }
cmd_run() { _cmd_run "$@"; }
cmd_serve_usage() { _cmd_serve_usage; }
cmd_serve() { _cmd_serve "$@"; }

# macOS Gatekeeper places a quarantine extended attribute on files downloaded
# from the internet, blocking execution until the user approves them in System
# Settings. Strip the attribute here so freshly downloaded llama.cpp binaries
# run without a Gatekeeper popup. No-ops on non-Darwin systems.
_clear_macos_quarantine() {
  local target="$1"

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v xattr >/dev/null 2>&1 || return 0

  # xattr -dr: -d delete, -r recursive. Strips the quarantine attribute from
  # the directory and all files inside it. '|| true' ignores errors (e.g. if
  # the attribute doesn't exist or the system is too old to support it).
  xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
}

# Detect the native arch asset suffix for the current macOS/Linux machine.
# Returns e.g. "macos-arm64", "macos-x86_64", "ubuntu-x64".
_detect_arch() {
  local os
  local machine
  os="$(uname -s)"
  machine="$(uname -m)"
  case "$os" in
    Darwin)
      case "$machine" in
        arm64)  echo "macos-arm64" ;;
        x86_64) echo "macos-x86_64" ;;
        *)      die "unsupported macOS architecture: $machine" ;;
      esac
      ;;
    Linux)
      case "$machine" in
        x86_64|amd64) echo "ubuntu-x64" ;;
        aarch64)      echo "ubuntu-arm64" ;;
        *)            die "unsupported Linux architecture: $machine" ;;
      esac
      ;;
    *) die "unsupported OS: $os" ;;
  esac
}

# Perform a GitHub API GET with appropriate headers and retry behaviour.
# -f: fail on HTTP errors (non-2xx); -s: silent mode (no progress meter);
# -S: still show errors despite -s; -L: follow redirects.
# The Accept and X-GitHub-Api-Version headers opt into the stable v3 JSON API.
_github_get() {
  local url="$1"
  curl -fsSL \
    --connect-timeout 15 \
    --max-time 30 \
    --retry 3 \
    --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    -H "User-Agent: ${SCRIPT_NAME}" \
    "$url"
}

# Fetch the release JSON for a given tag, or the latest numbered nightly release
# if tag is empty. GitHub's /releases/latest endpoint excludes prereleases, and
# llama.cpp publishes its rolling binary builds as b#### prereleases.
_get_release_json() {
  local tag="$1"
  if [[ -n "$tag" ]]; then
    _github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${tag}"
  else
    _github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=100" |
      jq 'map(select((.tag_name // "") | test("^b[0-9]+$"))) | first // {}'
  fi
}

# Return just the tag name string of the latest llama.cpp release.
# 'jq -r' outputs the raw string without JSON quotes.
_get_latest_tag() {
  _get_release_json "" | jq -r '.tag_name // empty'
}


_cmd_install_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME install [--backend <mlx|llama.cpp>] [--tag <release_tag>]
                           [--path <installation_root>] [--arch <arch>]
                           [--shell-profile | --no-shell-profile]
       $SCRIPT_NAME install --print-latest-tag

Installs all supported backends by default: llama.cpp always, plus mlx on macOS Apple Silicon.
Use --backend to restrict to a single backend.

Options:
  --backend <backend>   Backend to install: mlx or llama.cpp.
                        If omitted, installs all supported backends for this platform.
  --tag <tag>           llama.cpp only. Use a specific release tag (e.g. b5880). Defaults to latest.
  --path <dir>          llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
  --arch <arch>         llama.cpp only. Asset architecture suffix (e.g. macos-arm64, macos-x86_64,
                        ubuntu-x64, ubuntu-arm64). Auto-detected if omitted.
  --shell-profile       Allow corral to edit your shell profile for completion loading.
  --no-shell-profile    Never edit your shell profile. Default: ask if interactive, skip otherwise.
  --print-latest-tag    llama.cpp only. Print the latest release tag and exit.
EOF
}

_do_install() {
  local TAG="$1"
  local INSTALL_ROOT="$2"
  local ARCH="$3"
  local PROFILE_MODE="$4"

  INSTALL_ROOT="$(normalize_dir_path "$INSTALL_ROOT")"

  local ASSET_NAME="llama-${TAG}-bin-${ARCH}.tar.gz"
  local RELEASE_JSON
  echo "Fetching release metadata..."
  RELEASE_JSON="$(_get_release_json "$TAG")"

  # When TAG is empty, the API returns the latest release JSON. Extract the
  # actual tag name from it so we can construct the correct asset filename.
  if [[ -z "$TAG" || "$TAG" == "null" ]]; then
    TAG="$(jq -r '.tag_name' <<<"$RELEASE_JSON")"
    [[ -z "$TAG" || "$TAG" == "null" ]] && die "failed to determine latest release tag."
    ASSET_NAME="llama-${TAG}-bin-${ARCH}.tar.gz"
  fi

  local ASSET_URL
  # jq --arg: pass the shell variable as a jq variable $asset_name
  # (safer than string interpolation inside the jq filter).
  ASSET_URL="$({
    jq -r --arg asset_name "$ASSET_NAME" '
      .assets[]
      | select(.name == $asset_name)
      | .browser_download_url
    ' <<<"$RELEASE_JSON"
  })"

  [[ -z "$ASSET_URL" || "$ASSET_URL" == "null" ]] && \
    die "could not find asset '${ASSET_NAME}' in release '${TAG}'."

  local VERSION_DIR_NAME="llama-${TAG}"
  local TARGET_DIR="${INSTALL_ROOT}/${VERSION_DIR_NAME}"
  # A marker file written after successful extraction indicates a complete install.
  # If it exists we can skip downloading and re-extracting the archive.
  local MARKER_FILE="${TARGET_DIR}/.install-complete"
  local CURRENT_LINK="${INSTALL_ROOT}/current"

  mkdir -p "$INSTALL_ROOT"

  # Clean up any stale staging dirs left over from a previous interrupted install.
  find "$INSTALL_ROOT" -maxdepth 1 -type d -name ".${VERSION_DIR_NAME}.tmp.*" -exec rm -rf {} +

  if [[ -f "$MARKER_FILE" ]]; then
    echo "llama.cpp ${TAG} is already installed at: $TARGET_DIR"
    ln -sfn "$TARGET_DIR" "$CURRENT_LINK"
    install_path "$CURRENT_LINK" "$PROFILE_MODE"
    install_completions "$PROFILE_MODE" || true
    return 0
  fi

  local WORK_DIR
  WORK_DIR="$(mktemp -d)"
  local ARCHIVE_PATH="${WORK_DIR}/${ASSET_NAME}"
  local EXTRACT_DIR="${WORK_DIR}/extract"
  local STAGE_PARENT
  STAGE_PARENT="$(mktemp -d "${WORK_DIR}/stage.XXXXXX")"

  # Register a cleanup trap so the temporary work directory is always removed on
  # exit, whether the install succeeds, fails, or is interrupted by a signal.
  trap 'rm -rf -- "$WORK_DIR"' EXIT

  echo "Downloading asset: $ASSET_NAME"
  curl -fL \
    --connect-timeout 30 \
    --retry 3 \
    --retry-delay 5 \
    "$ASSET_URL" -o "$ARCHIVE_PATH"

  mkdir -p "$EXTRACT_DIR"

  echo "Extracting archive..."
  tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

  # dotglob: include dot-files in glob results.
  # nullglob: expand to nothing (not a literal glob string) when no files match.
  shopt -s dotglob nullglob
  local EXTRACTED_ITEMS=("$EXTRACT_DIR"/*)
  shopt -u dotglob nullglob

  [[ ${#EXTRACTED_ITEMS[@]} -ne 1 || ! -d "${EXTRACTED_ITEMS[0]}" ]] && \
    die "expected archive to contain exactly one top-level directory."

  local EXTRACTED_TOP_DIR="${EXTRACTED_ITEMS[0]}"
  local EXTRACTED_BASENAME
  EXTRACTED_BASENAME="$(basename "$EXTRACTED_TOP_DIR")"

  [[ "$EXTRACTED_BASENAME" != "$VERSION_DIR_NAME" ]] && \
    die "expected extracted directory '$VERSION_DIR_NAME', got '$EXTRACTED_BASENAME'."

  local STAGED_TARGET="${STAGE_PARENT}/${VERSION_DIR_NAME}"
  mv "$EXTRACTED_TOP_DIR" "$STAGED_TARGET"

  _clear_macos_quarantine "$STAGED_TARGET"

  # Write the completion marker before the final move; it will become
  # MARKER_FILE once the directory lands in its permanent location.
  touch "${STAGED_TARGET}/.install-complete"

  if [[ -e "$TARGET_DIR" ]]; then
    if [[ -f "$MARKER_FILE" ]]; then
      echo "llama.cpp ${TAG} is already installed at: $TARGET_DIR"
      ln -sfn "$TARGET_DIR" "$CURRENT_LINK"
      install_path "$CURRENT_LINK" "$PROFILE_MODE"
      install_completions "$PROFILE_MODE" || true
      rm -rf "$WORK_DIR"
      trap - EXIT
      return 0
    fi
    die "target exists but is incomplete: $TARGET_DIR"
  fi

  # Atomic rename: move the fully prepared staging directory to the final
  # location in a single step, so the install is never partially visible.
  echo "Activating install at: $TARGET_DIR"
  mv "$STAGED_TARGET" "$TARGET_DIR"

  # ln -sfn: -s symbolic, -f force (overwrite existing), -n don't follow
  # existing symlink target (treat it as a regular file to replace).
  echo "Updating current symlink..."
  ln -sfn "$TARGET_DIR" "$CURRENT_LINK"

  rm -rf "$WORK_DIR"
  trap - EXIT

  echo
  echo "Installed llama.cpp ${TAG} to: $TARGET_DIR"
  echo "Current version -> $CURRENT_LINK"
  install_path "$CURRENT_LINK" "$PROFILE_MODE"

  install_completions "$PROFILE_MODE" || true
}

# Ensure uv is available for MLX installation.
# Returns 0 when uv is already present or when Homebrew installation succeeds.
# Returns 1 when uv is still unavailable after any Homebrew attempt.
# shellcheck disable=SC2329
_ensure_uv_for_mlx() {
  if command -v uv >/dev/null 2>&1; then
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    if confirm_action "uv not found. Install uv via Homebrew to proceed?"; then
      brew install uv
      command -v uv >/dev/null 2>&1 && return 0
    fi
  fi

  return 1
}

# Install the MLX backend (mlx-lm Python package).
# Prefer uv to avoid pip issues with externally-managed Homebrew Python.
# If uv is missing, optionally install it via Homebrew.
# shellcheck disable=SC2329
_do_install_mlx() {
  require_mlx_platform

  if command -v mlx_lm.chat >/dev/null 2>&1 || command -v mlx_lm.generate >/dev/null 2>&1; then
    local version
    version="$(python3 -c "import mlx_lm; print(mlx_lm.__version__)" 2>/dev/null || echo "unknown")"
    echo "mlx-lm is already installed (${version})"
    return 0
  fi

  echo "Installing mlx-lm..."

  if ! _ensure_uv_for_mlx; then
    if command -v brew >/dev/null 2>&1; then
      die "Installation cancelled. Install uv to proceed: https://docs.astral.sh/uv/"
    fi
    die "uv is required for MLX installation. Install uv first: https://docs.astral.sh/uv/"
  fi

  uv tool install mlx-lm
  echo
  echo "Installed mlx-lm via uv."
}

# Non-fatal mlx-lm install. Mirrors _do_install_mlx but warns and returns 0
# instead of dying when prerequisites (uv) remain unavailable.
# Used by the combined (all-backends) install path so that a missing uv does
# not abort the entire install when only the llama.cpp half was essential.
# shellcheck disable=SC2329
_try_install_mlx() {
  require_mlx_platform

  if command -v mlx_lm.chat >/dev/null 2>&1 || command -v mlx_lm.generate >/dev/null 2>&1; then
    local version
    version="$(python3 -c 'import mlx_lm; print(mlx_lm.__version__)' 2>/dev/null || echo "unknown")"
    echo "mlx-lm is already installed (${version})"
    return 0
  fi

  echo "Installing mlx-lm..."

  if ! _ensure_uv_for_mlx; then
    echo "MLX prerequisites not available: uv not found." >&2
    echo "  Run: $SCRIPT_NAME install --backend mlx  (after installing uv: https://docs.astral.sh/uv/)" >&2
    return 0
  fi

  uv tool install mlx-lm
  echo
  echo "Installed mlx-lm via uv."
}

# Install or update llama.cpp from a GitHub release.
# Manages the argument-parsing loop common to all cmd_* functions:
# 'while [[ $# -gt 0 ]]; do case ... shift; done'
_cmd_install() {
  local TAG=""
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local PRINT_LATEST_TAG="false"
  local ARCH=""
  local PROFILE_MODE="ask"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_install_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      --tag)
        option_value_present "$@" || { echo "missing value for --tag" >&2; cmd_install_usage >&2; return 1; }
        TAG="$2"
        shift 2
        ;;
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_install_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --arch)
        option_value_present "$@" || { echo "missing value for --arch" >&2; cmd_install_usage >&2; return 1; }
        ARCH="$2"
        shift 2
        ;;
      --shell-profile)     PROFILE_MODE="always"; shift ;;
      --no-shell-profile)  PROFILE_MODE="never"; shift ;;
      --print-latest-tag)  PRINT_LATEST_TAG="true"; shift ;;
      -h|--help)           cmd_install_usage; return 0 ;;
      *)                   echo "Unknown argument: $1" >&2; cmd_install_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  case "${BACKEND_FLAG:-all}" in
    mlx)
      _do_install_mlx
      install_completions "$PROFILE_MODE" || true
      return 0
      ;;
  esac

  # --print-latest-tag is llama.cpp-only.
  if [[ "$PRINT_LATEST_TAG" == "true" ]]; then
    if [[ -n "$TAG" || "$INSTALL_ROOT" != "$DEFAULT_INSTALL_ROOT" ]]; then
      die "--print-latest-tag cannot be combined with --tag or --path."
    fi
    require_cmds curl jq
    local LATEST_TAG
    LATEST_TAG="$(_get_latest_tag)"
    [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && die "failed to determine latest release tag."
    printf '%s\n' "$LATEST_TAG"
    return 0
  fi

  # --backend llama.cpp or combined: install llama.cpp.
  require_cmds curl tar mktemp mv rm mkdir touch ln find jq basename

  [[ -z "$ARCH" ]] && ARCH="$(_detect_arch)"

  _do_install "$TAG" "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"

  case "${BACKEND_FLAG:-all}" in
    llama.cpp)
      return 0
      ;;
    all)
      # Combined path (no --backend): also install mlx if on Apple Silicon.
      if is_mlx_platform; then
        echo
        echo "Installing MLX backend..."
        _try_install_mlx
      fi
      ;;
  esac
}

_cmd_update_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME update [--backend <mlx|llama.cpp>] [--path <installation_root>] [--arch <arch>]
                          [--shell-profile | --no-shell-profile]

Updates all installed backends by default: llama.cpp always, plus mlx on macOS Apple Silicon.
Use --backend to restrict to a single backend.

Options:
  --backend <backend>
                  Backend to update: mlx or llama.cpp.
                  If omitted, updates all installed backends for this platform.
  --path <dir>    llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
  --arch <arch>   llama.cpp only. Asset architecture suffix. Auto-detected if omitted.
  --shell-profile Allow corral to edit your shell profile for PATH/completion loading.
  --no-shell-profile
                  Never edit your shell profile. Default: ask if interactive, skip otherwise.

Checks whether a newer backend release/package exists and installs it if so.
For mlx, upgrades mlx-lm via uv.
EOF
}

_update_mlx() {
  require_mlx_platform

  command -v uv >/dev/null 2>&1 || \
    die "uv is required to update MLX. Install uv first: https://docs.astral.sh/uv/"

  if ! command -v mlx_lm.chat >/dev/null 2>&1 && ! command -v mlx_lm.generate >/dev/null 2>&1; then
    die "mlx-lm is not installed. Run: $SCRIPT_NAME install --backend mlx"
  fi

  echo "Updating mlx-lm via uv..."
  uv tool upgrade mlx-lm
  echo "Done."
}

# Non-fatal mlx update. Mirrors _update_mlx but warns and returns 0 instead
# of dying when mlx-lm is not installed or uv is unavailable.
# Used by the combined (all-backends) update path for the same reason as
# _try_install_mlx: avoid aborting an otherwise successful llama.cpp update.
# shellcheck disable=SC2329
_try_update_mlx() {
  require_mlx_platform

  if ! command -v uv >/dev/null 2>&1; then
    echo "uv not found; skipping MLX update. Run: $SCRIPT_NAME update --backend mlx" >&2
    return 0
  fi

  if ! command -v mlx_lm.chat >/dev/null 2>&1 && ! command -v mlx_lm.generate >/dev/null 2>&1; then
    echo "mlx-lm not installed; skipping MLX update. Run: $SCRIPT_NAME install --backend mlx"
    return 0
  fi

  echo "Updating mlx-lm via uv..."
  uv tool upgrade mlx-lm
  echo "Done."
}

# Update llama.cpp to the latest release. Extracted from cmd_update so it can
# be called independently in the combined (all-backends) update path.
_update_llama() {
  local INSTALL_ROOT="$1"
  local ARCH="$2"
  local PROFILE_MODE="$3"

  INSTALL_ROOT="$(normalize_dir_path "$INSTALL_ROOT")"

  local CURRENT_LINK="${INSTALL_ROOT}/current"
  local INSTALLED_TAG=""
  if [[ -L "$CURRENT_LINK" ]]; then
    # Extract the installed tag from the symlink target directory name:
    # e.g. ~/.llama.cpp/llama-b5880 → basename → llama-b5880 → strip "llama-" → b5880
    INSTALLED_TAG="$(basename "$(readlink "$CURRENT_LINK")")"
    INSTALLED_TAG="${INSTALLED_TAG#llama-}"
  fi

  echo "Checking for latest llama.cpp release..."
  local LATEST_TAG
  LATEST_TAG="$(_get_latest_tag)"
  [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && die "failed to determine latest release tag."

  if [[ "$INSTALLED_TAG" == "$LATEST_TAG" ]]; then
    echo "Already up to date: llama.cpp ${LATEST_TAG}"
    return 0
  fi

  if [[ -n "$INSTALLED_TAG" ]]; then
    echo "Updating llama.cpp: ${INSTALLED_TAG} -> ${LATEST_TAG}"
  else
    echo "No existing llama.cpp installation found. Installing ${LATEST_TAG}..."
  fi

  require_cmds curl tar mktemp mv rm mkdir touch ln find basename
  _do_install "$LATEST_TAG" "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
}

_cmd_update() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local ARCH=""
  local PROFILE_MODE="ask"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_update_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_update_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --arch)
        option_value_present "$@" || { echo "missing value for --arch" >&2; cmd_update_usage >&2; return 1; }
        ARCH="$2"
        shift 2
        ;;
      --shell-profile)    PROFILE_MODE="always"; shift ;;
      --no-shell-profile) PROFILE_MODE="never"; shift ;;
      -h|--help) cmd_update_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_update_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  case "${BACKEND_FLAG:-all}" in
    mlx)
      _update_mlx
      return 0
      ;;
  esac

  require_cmds curl jq
  [[ -z "$ARCH" ]] && ARCH="$(_detect_arch)"

  case "${BACKEND_FLAG:-all}" in
    llama.cpp)
      _update_llama "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
      ;;
    all)
      # Combined path (no --backend): update llama.cpp and mlx if on Apple Silicon.
      _update_llama "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
      if is_mlx_platform; then
        echo
        _try_update_mlx
      fi
      ;;
  esac
}

_cmd_status_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME status [--backend <mlx|llama.cpp>] [--path <installation_root>] [--check-update]

Shows installation status for all supported backends on this platform.
Without --backend, shows all installed backends.

Options:
  --backend <backend>  Show status for a single backend: mlx or llama.cpp.
                       If omitted, shows all supported backends for this platform.
  --path <dir>         llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
  --check-update       llama.cpp only. Also query GitHub for the latest available release tag.
EOF
}

# Resolve mlx-lm version across different install layouts.
_mlx_lm_version() {
  local version=''

  if command -v python3 >/dev/null 2>&1; then
    version="$(python3 -c 'import mlx_lm; print(mlx_lm.__version__)' 2>/dev/null || true)"
  fi

  if [[ -z "$version" ]] && command -v uv >/dev/null 2>&1; then
    local tool_line
    tool_line="$(uv tool list 2>/dev/null | awk '$1 == "mlx-lm" {print; exit}')"
    if [[ -n "$tool_line" ]]; then
      version="$(printf '%s\n' "$tool_line" | grep -Eo '[0-9]+(\.[0-9]+){1,3}([A-Za-z0-9._-]+)?' | head -n1 || true)"
    fi
  fi

  if [[ -z "$version" ]]; then
    echo "unknown"
  else
    echo "$version"
  fi
}

_cmd_status() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local CHECK_UPDATE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_status_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --check-update)  CHECK_UPDATE="true"; shift ;;
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_status_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      -h|--help)       cmd_status_usage; return 0 ;;
      *)               echo "Unknown argument: $1" >&2; cmd_status_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  echo "Platform  : $(uname -s)/$(uname -m)"

  case "${BACKEND_FLAG:-all}" in
    mlx|llama.cpp)
      local BACKEND
      BACKEND="$(resolve_backend "$BACKEND_FLAG")"
      echo "Backend   : $BACKEND"
      echo
      if [[ "$BACKEND" == "mlx" ]]; then
        _status_mlx
      else
        _status_llama "$INSTALL_ROOT" "$CHECK_UPDATE"
      fi
      ;;
    all)
      # Combined path (no --backend): show all supported backends.
      echo
      _status_llama "$INSTALL_ROOT" "$CHECK_UPDATE"

      if is_mlx_platform; then
        echo
        _status_mlx
      fi
      ;;
  esac
}

# Print llama.cpp installation status.
_status_llama() {
  local INSTALL_ROOT="$1"
  local CHECK_UPDATE="$2"

  INSTALL_ROOT="$(normalize_dir_path "$INSTALL_ROOT")"

  local CURRENT_LINK="${INSTALL_ROOT}/current"

  if [[ ! -L "$CURRENT_LINK" && ! -d "$CURRENT_LINK" ]]; then
    echo "llama.cpp : not installed (${INSTALL_ROOT})"
    return 0
  fi

  local INSTALLED_TAG=""
  if [[ -L "$CURRENT_LINK" ]]; then
    INSTALLED_TAG="$(basename "$(readlink "$CURRENT_LINK")")"
    INSTALLED_TAG="${INSTALLED_TAG#llama-}"
  fi

  echo "llama.cpp : ${INSTALLED_TAG:-unknown} (${CURRENT_LINK})"

  if [[ "$CHECK_UPDATE" == "true" ]]; then
    require_cmds curl jq
    echo -n "Latest    : "
    local LATEST_TAG
    LATEST_TAG="$(_get_latest_tag)"
    if [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]]; then
      echo "(could not fetch)"
    elif [[ "$LATEST_TAG" == "$INSTALLED_TAG" ]]; then
      echo "${LATEST_TAG} (up to date)"
    else
      echo "${LATEST_TAG} (update available — run: $SCRIPT_NAME update)"
    fi
  fi
}

# Print MLX installation status.
_status_mlx() {
  if command -v mlx_lm.generate >/dev/null 2>&1 || command -v mlx_lm.chat >/dev/null 2>&1; then
    local version
    version="$(_mlx_lm_version)"
    echo "mlx-lm    : installed (${version})"
  else
    echo "mlx-lm    : not installed (run: $SCRIPT_NAME install --backend mlx)"
  fi
}

# Emit installed engine rows for list output (no header).
# Each row uses the format: ENGINE<TAB>VERSION
# shellcheck disable=SC2329
_emit_installed_engine_rows() {
  local root="$1"
  root="$(normalize_dir_path "$root")"

  local current_link="${root}/current"
  if [[ -L "$current_link" || -d "$current_link" ]]; then
    local installed_tag='unknown'
    if [[ -L "$current_link" ]]; then
      installed_tag="$(basename "$(readlink "$current_link")")"
      installed_tag="${installed_tag#llama-}"
    fi
    printf '%s\t%s\n' 'llama.cpp' "$installed_tag"
  fi

  if command -v mlx_lm.generate >/dev/null 2>&1 || command -v mlx_lm.chat >/dev/null 2>&1; then
    local version
    version="$(_mlx_lm_version)"
    printf '%s\t%s\n' 'mlx-lm' "$version"
  fi
}

_cmd_uninstall_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME uninstall [--backend <mlx|llama.cpp>] [--path <installation_root>] [--delete-hf-cache] [--self] [--force]

Uninstalls all backends by default: llama.cpp always, plus mlx on macOS Apple Silicon.
Use --backend to restrict to a single backend.

Options:
  --backend <backend>   Backend to uninstall: mlx or llama.cpp.
                        If omitted, uninstalls all supported backends for this platform.
  --path <dir>          llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
  --delete-hf-cache    Also delete cached model directories under ~/.cache/huggingface/hub.
  --self               Also delete the corral script itself.
  --force              Skip confirmation prompts.

For mlx, removes mlx-lm (via uv when available).
EOF
}

_delete_hf_model_cache_dirs() {
  if [[ ! -d "$HF_HUB_DIR" ]]; then
    echo "No HuggingFace model cache found at: $HF_HUB_DIR"
    return 0
  fi

  local model_dirs=()
  local dir
  for dir in "$HF_HUB_DIR"/models--*; do
    [[ -d "$dir" ]] || continue
    model_dirs+=("$dir")
  done

  if [[ ${#model_dirs[@]} -eq 0 ]]; then
    echo "No cached model directories found under: $HF_HUB_DIR"
    return 0
  fi

  echo "Removing ${#model_dirs[@]} cached HuggingFace model director(ies) from: $HF_HUB_DIR"
  rm -rf "${model_dirs[@]}"
  echo "Done."
}

# Uninstall mlx-lm.
# Used by cmd_uninstall for both the scoped (--backend mlx) and combined paths.
_uninstall_mlx_components() {
  local FORCE="$1"

  local mlx_installed="false"
  if command -v mlx_lm.chat >/dev/null 2>&1 || command -v mlx_lm.generate >/dev/null 2>&1; then
    mlx_installed="true"
  fi

  if [[ "$mlx_installed" == "true" ]]; then
    if command -v uv >/dev/null 2>&1; then
      confirm_destructive_action "uninstalling mlx-lm" "$FORCE" || return 1
      echo "Uninstalling mlx-lm..."
      uv tool uninstall mlx-lm
    else
      echo "Warning: uv not found; skipping mlx-lm uninstall. Remove manually if needed." >&2
    fi
  else
    echo "mlx-lm is not installed."
  fi

}

# Remove the llama.cpp installation root.
# Used by cmd_uninstall for both the scoped (--backend llama.cpp) and combined paths.
_uninstall_llama_components() {
  local INSTALL_ROOT="$1"
  local FORCE="$2"

  INSTALL_ROOT="$(normalize_dir_path "$INSTALL_ROOT")"

  if [[ -d "$INSTALL_ROOT" ]]; then
    confirm_destructive_action "removing the llama.cpp installation at ${INSTALL_ROOT}" "$FORCE" || return 1
    echo "Removing llama.cpp installation at: $INSTALL_ROOT"
    rm -rf "$INSTALL_ROOT"
    echo "Done."
  else
    echo "Nothing to uninstall at: $INSTALL_ROOT"
  fi
}

# Handle the options shared across all uninstall paths: --delete-hf-cache and --self.
_uninstall_shared_options() {
  local DELETE_HF_CACHE="$1"
  local DELETE_SELF="$2"
  local FORCE="$3"

  if [[ "$DELETE_HF_CACHE" == "true" ]]; then
    confirm_destructive_action "removing cached HuggingFace model directories under ${HF_HUB_DIR}" "$FORCE" || return 1
    _delete_hf_model_cache_dirs
  fi

  if [[ "$DELETE_SELF" == "true" ]]; then
    local self_path
    # 'command -v' locates the script on PATH; '|| true' prevents set -e
    # from aborting if the script isn't found.
    self_path="$(command -v "$SCRIPT_NAME" 2>/dev/null || true)"
    if [[ -z "$self_path" ]]; then
      echo "Could not locate $SCRIPT_NAME on PATH; skipping self-removal."
    else
      confirm_destructive_action "removing $SCRIPT_NAME at ${self_path}" "$FORCE" || return 1
      echo "Removing $SCRIPT_NAME at: $self_path"
      rm -f "$self_path"
      echo "Done."
    fi
  fi
}

_cmd_uninstall() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local DELETE_HF_CACHE="false"
  local DELETE_SELF="false"
  local FORCE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_uninstall_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_uninstall_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --delete-hf-cache)  DELETE_HF_CACHE="true"; shift ;;
      --models)
        echo "Warning: --models is deprecated; use --delete-hf-cache instead." >&2
        DELETE_HF_CACHE="true"
        shift
        ;;
      --self)             DELETE_SELF="true"; shift ;;
      --force)            FORCE="true"; shift ;;
      -h|--help)          cmd_uninstall_usage; return 0 ;;
      *)                  echo "Unknown argument: $1" >&2; cmd_uninstall_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  case "${BACKEND_FLAG:-all}" in
    mlx)
      _uninstall_mlx_components "$FORCE" || return 1
      ;;
    llama.cpp)
      _uninstall_llama_components "$INSTALL_ROOT" "$FORCE" || return 1
      ;;
    all)
      # Combined path (no --backend): uninstall all supported backends.
      if is_mlx_platform; then
        echo "--- MLX backend ---"
        _uninstall_mlx_components "$FORCE" || return 1
        echo
      fi

      echo "--- llama.cpp backend ---"
      _uninstall_llama_components "$INSTALL_ROOT" "$FORCE" || return 1
      ;;
  esac

  # Shared options run once regardless of how many backends were uninstalled.
  _uninstall_shared_options "$DELETE_HF_CACHE" "$DELETE_SELF" "$FORCE"
}

_cmd_versions_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME versions [--backend <mlx|llama.cpp>] [--path <installation_root>]

Shows installed backend versions.
Without --backend, shows all installed backends for this platform.
For --backend mlx, prints only the installed mlx-lm package version.
For --backend llama.cpp, lists all installed llama.cpp release versions.

Options:
  --backend <backend>
                Backend to inspect: mlx or llama.cpp.
                If omitted, shows all installed backends for this platform.
  --path <dir>   llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
EOF
}

# Emit llama.cpp version rows (no header) for the given installation root.
# Each row uses the format: TYPE<TAB>VERSION<TAB>STATUS
# shellcheck disable=SC2329
_emit_llama_version_rows() {
  local root="$1"
  root="$(normalize_dir_path "$root")"

  if [[ ! -d "$root" ]]; then
    printf '%s\t%s\t%s\n' 'llama.cpp' '(no installation)' '-'
    return 0
  fi

  local current_link="${root}/current"
  local current_dir=""
  if [[ -L "$current_link" ]]; then
    current_dir="$(readlink "$current_link")"
    # If the readlink result is relative, make it absolute by prepending root.
    [[ "$current_dir" != /* ]] && current_dir="${root}/${current_dir}"
  fi

  local found=0
  local dir
  for dir in "$root"/llama-*/; do
    # Glob may match literally "llama-*/" if no directories exist; skip non-dirs.
    [[ -d "$dir" ]] || continue
    found=1
    local tag
    tag="$(basename "$dir")"
    # ${tag#llama-}: strip the "llama-" prefix, leaving just the version tag.
    tag="${tag#llama-}"
    local dir_abs="${dir%/}"
    if [[ "$dir_abs" == "$current_dir" ]]; then
      printf '%s\t%s\t%s\n' 'llama.cpp' "$tag" 'current'
    else
      printf '%s\t%s\t%s\n' 'llama.cpp' "$tag" '-'
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    printf '%s\t%s\t%s\n' 'llama.cpp' '(no versions)' '-'
  fi
}

# Emit mlx version row (no header).
# Each row uses the format: TYPE<TAB>VERSION<TAB>STATUS
# shellcheck disable=SC2329
_emit_mlx_version_rows() {
  if command -v mlx_lm.chat >/dev/null 2>&1 || command -v mlx_lm.generate >/dev/null 2>&1; then
    local version
    version="$(_mlx_lm_version)"
    printf '%s\t%s\t%s\n' 'mlx' "$version" 'installed'
  else
    printf '%s\t%s\t%s\n' 'mlx' '(not installed)' '-'
  fi
}

_cmd_versions() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_versions_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_versions_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      -h|--help) cmd_versions_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_versions_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  case "${BACKEND_FLAG:-all}" in
    mlx)
      _emit_mlx_version_rows | print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
      ;;
    llama.cpp)
      _emit_llama_version_rows "$INSTALL_ROOT" | print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
      ;;
    all)
      # Combined path (no --backend): show all installed backends.
      {
        _emit_llama_version_rows "$INSTALL_ROOT"

        if is_mlx_platform; then
          _emit_mlx_version_rows
        fi
      } | print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
      ;;
  esac
}

_cmd_prune_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME prune [--backend <mlx|llama.cpp>] [--path <installation_root>] [--force]

Removes all installed llama.cpp versions except the currently active one.
For --backend mlx, prune is a no-op (model pruning is not supported).

Options:
  --backend <backend>
                Backend scope: mlx or llama.cpp (default: llama.cpp).
  --path <dir>   llama.cpp only. Installation root. Defaults to ~/.llama.cpp.
  --force        Skip confirmation prompt.
EOF
}

_cmd_prune() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local FORCE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        option_value_present "$@" || { echo "missing value for --backend" >&2; cmd_prune_usage >&2; return 1; }
        BACKEND_FLAG="$2"
        shift 2
        ;;
      --path)
        option_value_present "$@" || { echo "missing value for --path" >&2; cmd_prune_usage >&2; return 1; }
        INSTALL_ROOT="$2"
        shift 2
        ;;
      --force)   FORCE="true"; shift ;;
      -h|--help) cmd_prune_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_prune_usage >&2; return 1 ;;
    esac
  done

  validate_backend_flag "$BACKEND_FLAG"

  local BACKEND="llama.cpp"
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    echo "Nothing to prune for MLX. 'prune' only removes old llama.cpp installs."
    return 0
  fi

  INSTALL_ROOT="$(normalize_dir_path "$INSTALL_ROOT")"

  local current_link="${INSTALL_ROOT}/current"
  local current_dir=""
  if [[ -L "$current_link" ]]; then
    current_dir="$(readlink "$current_link")"
    # readlink may return a relative path; make it absolute for comparison.
    [[ "$current_dir" != /* ]] && current_dir="${INSTALL_ROOT}/${current_dir}"
  fi

  if [[ -z "$current_dir" || ! -d "$current_dir" ]]; then
    die "no active version found at ${current_link}; refusing to prune. Run '$SCRIPT_NAME install' first."
  fi

  local to_remove=()
  local dir
  for dir in "$INSTALL_ROOT"/llama-*/; do
    [[ -d "$dir" ]] || continue
    local dir_abs="${dir%/}"
    [[ "$dir_abs" == "$current_dir" ]] && continue
    to_remove+=("$dir_abs")
  done

  if [[ ${#to_remove[@]} -eq 0 ]]; then
    echo "Nothing to prune. Only the current version is installed."
    return 0
  fi

  echo "The following versions will be removed:"
  local d
  for d in "${to_remove[@]}"; do
    local size
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    printf '  %s  (%s)\n' "$(basename "$d")" "$size"
  done
  echo
  confirm_destructive_action "removing ${#to_remove[@]} old version(s) from ${INSTALL_ROOT}" "$FORCE" || return 1

  for d in "${to_remove[@]}"; do
    echo "Removing: $(basename "$d")"
    rm -rf "$d"
  done
  echo "Done."
}

# ── pull ──────────────────────────────────────────────────────────────────────

_cmd_pull_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME pull [--backend <mlx|llama.cpp>] <MODEL_NAME[:QUANT]>

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  QUANT         Optional quant tag to download a specific variant (llama.cpp only; e.g. Q4_K_M, UD-Q6_K).

Downloads (pre-warms) a HuggingFace model into the local cache without running it.
The backend is auto-detected from the model name by default: repos ending in -GGUF use
llama-cli; all others use mlx_lm.generate on Apple Silicon or llama-cli elsewhere.
Pass --backend to override when auto-detection is wrong.
EOF
}

_cmd_pull() {
  if [[ $# -eq 0 ]]; then
    cmd_pull_usage
    return 1
  fi

  local BACKEND_FLAG=""
  local model_spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        if ! option_value_present "$@"; then
          echo "missing value for --backend" >&2
          cmd_pull_usage >&2
          return 1
        fi
        BACKEND_FLAG="$2"
        shift 2
        ;;
      -h|--help)
        cmd_pull_usage
        return 0
        ;;
      *)
        if [[ -z "$model_spec" ]]; then
          model_spec="$1"
          shift
        else
          echo "Unknown argument: $1" >&2
          cmd_pull_usage >&2
          return 1
        fi
        ;;
    esac
  done

  if [[ -z "$model_spec" ]]; then
    cmd_pull_usage >&2
    return 1
  fi

  local BACKEND
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  else
    BACKEND="$(_infer_pull_backend "$model_spec")"
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    _pull_mlx "$model_spec"
    return 0
  fi

  parse_model_spec "$model_spec"
  local model_name="$REPLY_MODEL"
  local quant="$REPLY_QUANT"
  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"

  local requires_mtp_sidecar="false"
  local mtp_sidecar_path=""
  if [[ "$BACKEND" == "llama.cpp" ]] && _hf_model_mtp_sidecar_path "$model_name"; then
    # llama-cli can download an MTP drafter before resolving the primary
    # --hf model, then fail with "--model is required". Pull the primary
    # model normally and fetch the advertised drafter after its snapshot
    # exists instead.
    mtp_sidecar_path="$REPLY_MTP_SIDECAR_PATH"
    requires_mtp_sidecar="true"
  fi

  ensure_llama_in_path
  require_cmds llama-cli

  if cache_has_model_or_quant "$cache_dir" "$quant"; then
    if [[ "$requires_mtp_sidecar" == "true" ]] && ! _cache_dir_has_mtp_sidecar "$cache_dir" "$mtp_sidecar_path"; then
      :
    else
      echo "Model already cached: $model_spec"
      echo "  $cache_dir"
      return 0
    fi
  fi

  local preexisting_gguf_paths=''
  if [[ -n "$quant" && -d "$cache_dir" ]]; then
    preexisting_gguf_paths="$(find_cached_gguf_paths "$cache_dir")"
  fi

  echo "Pulling model: $model_spec"
  # Force a non-conversation single turn with a non-empty placeholder prompt so
  # llama-cli downloads into the HF cache and exits instead of entering chat
  # mode on models that advertise a chat template by default.
  # Invoke llama-cli just long enough to warm the HF cache, then exit:
  # --single-turn: one-shot mode so the process exits after one pass.
  # --prompt ' ': a single space avoids the "no prompt" error raised by some models.
  # --no-display-prompt: suppress the placeholder prompt from being printed.
  # -n 0: predict zero tokens so llama-cli exits immediately after model loading.
  # </dev/null: close stdin to prevent llama-cli from reading interactively.
  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local hf_args=()
  [[ -n "$hf_token" ]] && hf_args=(--hf-token "$hf_token")
  # '|| pull_status=$?': capture llama-cli's exit code instead of letting
  # set -e abort the script on non-zero. We check pull_status below to
  # provide a more helpful error message.
  local pull_status=0
  llama-cli -hf "$model_spec" "${hf_args[@]+"${hf_args[@]}"}" \
    --single-turn --prompt ' ' --no-display-prompt -n 0 </dev/null || pull_status=$?

  if cache_has_model_or_quant "$cache_dir" "$quant"; then
    if [[ -n "$quant" ]]; then
      _cleanup_unrequested_quant_pull_ggufs "$cache_dir" "$quant" "$preexisting_gguf_paths"
    fi
    if [[ "$requires_mtp_sidecar" == "true" ]] && ! _cache_dir_has_mtp_sidecar "$cache_dir" "$mtp_sidecar_path"; then
      _download_hf_mtp_sidecar "$model_name" "$mtp_sidecar_path" "$cache_dir" || true
    fi
    if [[ "$requires_mtp_sidecar" == "true" ]] && ! _cache_dir_has_mtp_sidecar "$cache_dir" "$mtp_sidecar_path"; then
      die "pull did not download required MTP sidecar for '${model_spec}' (cache dir: ${cache_dir})"
    fi
    echo "Done: $model_spec"
    return 0
  fi

  if [[ $pull_status -ne 0 ]]; then
    die "pull failed for '${model_spec}' (llama-cli exit ${pull_status}); expected cache dir was not created: ${cache_dir}"
  fi

  if [[ -z "$quant" ]]; then
    die "pull did not create the expected cache dir: ${cache_dir}"
  fi

  die "pull did not cache requested quant '${quant}' for model '${model_name}' (cache dir: ${cache_dir})"
}

# Return success if the cache already includes an auxiliary MTP sidecar.
_cache_dir_has_mtp_sidecar() {
  local cache_dir="$1"
  local sidecar_path="${2:-}"
  local snapshot_dir
  local path

  for snapshot_dir in "$cache_dir"/snapshots/*/; do
    [[ -d "$snapshot_dir" ]] || continue
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if [[ -n "$sidecar_path" && "$path" != "${snapshot_dir%/}/${sidecar_path}" ]]; then
        continue
      fi
      if _is_mtp_sidecar_gguf_filename "$(basename "$path")"; then
        return 0
      fi
    done < <(find "$snapshot_dir" \( -type f -o -type l \) -name '*.gguf' -print)
  done

  return 1
}

# Fetch Hugging Face model metadata as JSON. Returns 0 on success.
_fetch_hf_model_metadata() {
  local model_name="$1"
  [[ "$model_name" == */* ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  curl -fsSL \
    --connect-timeout 15 \
    --max-time 30 \
    --retry 3 \
    --retry-delay 2 \
    "${auth_header[@]+"${auth_header[@]}"}" \
    "https://huggingface.co/api/models/${model_name}" 2>/dev/null
}

# Download an MTP sidecar directly when llama.cpp cannot resolve a nested
# sidecar path such as MTP/mtp-model-Q4_0.gguf. The file is placed in the
# existing snapshot so the normal cache discovery path sees it.
_download_hf_mtp_sidecar() {
  local model_name="$1"
  local sidecar_path="$2"
  local cache_dir="$3"
  [[ "$model_name" == */* && -n "$sidecar_path" && -d "$cache_dir" ]] || return 1
  [[ "$sidecar_path" != /* && "$sidecar_path" != *".."* ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local snapshot_dir=""
  local candidate
  for candidate in "$cache_dir"/snapshots/*/; do
    [[ -d "$candidate" ]] || continue
    snapshot_dir="$candidate"
    break
  done
  [[ -n "$snapshot_dir" ]] || return 1

  local target_path="${snapshot_dir%/}/${sidecar_path}"
  if [[ -f "$target_path" || -L "$target_path" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$target_path")" || return 1

  local temp_path="${target_path}.corral-part.$$"
  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local auth_header=()
  [[ -n "$hf_token" ]] && auth_header=(-H "Authorization: Bearer ${hf_token}")

  echo "Downloading MTP sidecar: ${sidecar_path}"
  if ! curl -fL \
    --connect-timeout 15 \
    --retry 3 \
    --retry-delay 2 \
    "${auth_header[@]+"${auth_header[@]}"}" \
    "https://huggingface.co/${model_name}/resolve/main/${sidecar_path}" \
    -o "$temp_path"; then
    rm -f "$temp_path"
    return 1
  fi

  mv "$temp_path" "$target_path"
}

# Populate REPLY_MTP_SIDECAR_PATH with the preferred MTP draft sidecar
# advertised by Hugging Face metadata. llama.cpp auto-discovers a root-level
# mtp-*.gguf file from the primary --hf repository, so prefer that over the
# higher-precision files commonly kept under MTP/.
_hf_model_mtp_sidecar_path() {
  local model_name="$1"
  [[ "$model_name" == */* ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  REPLY_MTP_SIDECAR_PATH=""

  local metadata
  metadata="$(_fetch_hf_model_metadata "$model_name" || return 1)"

  local sidecar_path
  sidecar_path="$(jq -r '
    first(
      (.siblings // [])[]?
      | (.rfilename // "")
      | select(
          (ascii_downcase | startswith("mtp-")) and
          (ascii_downcase | endswith(".gguf"))
        )
    ) // first(
      (.siblings // [])[]?
      | (.rfilename // "")
      | select(
          (((ascii_downcase | contains("/mtp-")) or
            (ascii_downcase | contains("draft-mtp"))) and
           (ascii_downcase | endswith(".gguf")))
        )
    ) // empty
  ' <<<"$metadata")"
  [[ -n "$sidecar_path" ]] || return 1
  REPLY_MTP_SIDECAR_PATH="$sidecar_path"
}

# Return success if the Hugging Face metadata for a model advertises an MTP
# draft sidecar. Kept as a small compatibility wrapper for sourced callers.
_hf_model_has_mtp_sidecar() {
  _hf_model_mtp_sidecar_path "$1"
}

# Infer a backend hint from Hugging Face model metadata.
# Prints "llama.cpp", "mlx", or nothing when the metadata is unavailable or
# inconclusive. This keeps pull fast for obvious cases while avoiding a wrong
# platform-default dispatch for GGUF repos whose names do not end in -GGUF.
_infer_pull_backend_from_hf_metadata() {
  local model_name="$1"
  [[ "$model_name" == */* ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local metadata
  metadata="$(_fetch_hf_model_metadata "$model_name" || return 1)"

  if jq -e '
      (((.tags // []) | map(ascii_downcase) | index("gguf")) != null) or
      ((.siblings // []) | any(.rfilename?; (. // "" | ascii_downcase | endswith(".gguf"))))
    ' >/dev/null 2>&1 <<<"$metadata"; then
    printf 'llama.cpp'
    return 0
  fi

  if jq -e '
      (((.tags // []) | map(ascii_downcase) | index("mlx")) != null) or
      (((.library_name // "") | ascii_downcase) == "mlx")
    ' >/dev/null 2>&1 <<<"$metadata"; then
    printf 'mlx'
    return 0
  fi

  return 1
}

# Infer the backend for 'pull' from the model spec alone (nothing is cached yet).
# Decision order:
#   1. An explicit quant specifier ("user/model:Q4_K_M") → llama.cpp.
#      MLX backends never use colon-separated quant tags; a ":quant" suffix
#      is an unambiguous GGUF signal regardless of repo naming.
#   2. Repo name ends in -GGUF (case-insensitive) → llama.cpp.
#   3. Remote HF metadata says GGUF → llama.cpp.
#   4. Otherwise -> default backend (llama.cpp everywhere).
# Note: this still queries HF metadata first so obvious GGUF repos can be
# routed explicitly before falling back to the llama.cpp default.
_infer_pull_backend() {
  local model_spec="$1"
  local model_name="${model_spec%%:*}"
  # An explicit quant specifier is only meaningful for GGUF/llama.cpp models.
  if [[ "$model_spec" == *:* ]]; then
    printf 'llama.cpp'
    return 0
  fi
  if [[ "$model_name" =~ -[Gg][Gg][Uu][Ff]$ ]]; then
    printf 'llama.cpp'
    return 0
  fi
  local metadata_backend
  metadata_backend="$(_infer_pull_backend_from_hf_metadata "$model_name" || true)"
  if [[ -n "$metadata_backend" ]]; then
    printf '%s' "$metadata_backend"
    return 0
  fi
  platform_default_backend
}

# Pull a model via mlx_lm.generate (MLX backend).
# Remove newly downloaded GGUF files that do not match a quant-scoped pull.
# Some repos include auxiliary GGUF artifacts (for example nested BF16 files)
# that llama-cli may fetch alongside the requested quant. Preserve any GGUFs
# that were already present before the pull, but remove newly added non-matching
# files so `corral ls` reflects the explicitly requested quant.
_cleanup_unrequested_quant_pull_ggufs() {
  local cache_dir="$1"
  local requested_quant="$2"
  local preexisting_paths="${3:-}"
  local current_path

  while IFS= read -r current_path; do
    [[ -z "$current_path" ]] && continue

    if _is_auxiliary_gguf_filename "$(basename "$current_path")"; then
      continue
    fi

    if [[ -n "$preexisting_paths" ]] && grep -Fqx "$current_path" <<<"$preexisting_paths"; then
      continue
    fi

    local tag
    tag="$(extract_quant_from_filename "$(basename "$current_path")")"
    if [[ "$(normalize_quant_tag "$tag")" == "$(normalize_quant_tag "$requested_quant")" ]]; then
      continue
    fi

    if [[ -L "$current_path" ]]; then
      local blob_path
      blob_path="$(resolve_link "$current_path")"
      if [[ -f "$blob_path" ]]; then
        rm -f "$blob_path"
      fi
    fi
    rm -f "$current_path"
  done < <(find_cached_gguf_paths "$cache_dir")
}

_pull_mlx() {
  local input_spec="$1"
  local model_spec="$1"

  require_mlx_platform
  command -v mlx_lm.generate >/dev/null 2>&1 || \
    die "mlx_lm.generate not found. Install it first: $SCRIPT_NAME install --backend mlx"

  if [[ "$model_spec" == *:* ]]; then
    echo "Warning: MLX backend does not use quant specifiers; ignoring ':${model_spec#*:}'." >&2
    model_spec="${model_spec%%:*}"
  fi

  if [[ "$model_spec" != */* ]]; then
    die "profiles are not supported with the MLX backend. Use a HuggingFace model id (USER/MODEL)."
  fi

  echo "Pulling model: $input_spec"

  local pull_status=0
  mlx_lm.generate --model "$model_spec" --prompt ' ' --max-tokens 1 || pull_status=$?

  if [[ $pull_status -ne 0 ]]; then
    die "pull failed for '${input_spec}' (mlx_lm.generate exit ${pull_status})"
  fi

  echo "Done: $input_spec"
}

# ── run ───────────────────────────────────────────────────────────────────────

# Infer the backend required for run/serve from the model spec plus any local
# cache evidence.
#
# Decision tree, in order:
#   1. Cached GGUF files under the model's HF cache dir -> llama.cpp
#      Local cache is the strongest signal because it reflects what was actually
#      downloaded, not just how the repo is named.
#   2. Repo name ends in -GGUF -> llama.cpp
#      This handles uncached but clearly GGUF-scoped HuggingFace repos.
#   3. Any other USER/MODEL HuggingFace id -> mlx
#      run/serve prefer the MLX path for non-GGUF repos; callers can override
#      with --backend when the heuristic is wrong.
#   4. Non-HF specs (no slash) -> platform default
#      This catches local names that will later resolve through profiles.
#
# See also: _infer_pull_backend(), which uses a simpler heuristic because there
# is no local cache evidence yet at pull time.
_infer_model_backend() {
  local model_spec="$1"
  # Strip quant spec: "user/model:Q4_K_M" → "user/model"
  local model_name="${model_spec%%:*}"

  # Only check cache for valid USER/MODEL specs (contain a '/').
  if [[ "$model_name" == */* ]]; then
    # Check for GGUF files in the local HF cache.
    local cache_dir
    cache_dir="$(model_name_to_cache_dir "$model_name" 2>/dev/null || true)"
    if [[ -n "$cache_dir" && -d "$cache_dir" ]] && cache_dir_has_gguf "$cache_dir"; then
      printf 'llama.cpp'
      return 0
    fi

    # No cache evidence: use repo name as a signal.
    # Repos ending in -GGUF are always llama.cpp regardless of platform.
    if [[ "$model_name" =~ -[Gg][Gg][Uu][Ff]$ ]]; then
      printf 'llama.cpp'
      return 0
    fi

    # No GGUF evidence: assume MLX for USER/MODEL specs.
    printf 'mlx'
    return 0
  fi

  # No local evidence; fall back to the platform default.
  # On macOS Apple Silicon this is mlx; everywhere else it is llama.cpp.
  platform_default_backend
}

# Parse the shared argument shape used by 'run' and 'serve'.
#
# Usage:
#   _parse_model_command_args [--backend <mlx|llama.cpp>] <MODEL|PROFILE> [-- <extra args...>]
#
# Sets:
#   REPLY_MODEL_COMMAND_BACKEND_FLAG -> raw --backend value, or empty
#   REPLY_MODEL_COMMAND_MODEL_SPEC   -> model spec or profile name
#   REPLY_MODEL_COMMAND_EXTRA_ARGS   -> extra backend args after '--'
#   REPLY_MODEL_COMMAND_ERROR        -> explanatory error string on failure
_parse_model_command_args() {
  REPLY_MODEL_COMMAND_BACKEND_FLAG=""
  REPLY_MODEL_COMMAND_MODEL_SPEC=""
  REPLY_MODEL_COMMAND_EXTRA_ARGS=()
  REPLY_MODEL_COMMAND_ERROR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        if ! option_value_present "$@"; then
          REPLY_MODEL_COMMAND_ERROR="missing value for --backend"
          return 1
        fi
        REPLY_MODEL_COMMAND_BACKEND_FLAG="$2"
        validate_backend_flag "$REPLY_MODEL_COMMAND_BACKEND_FLAG"
        shift 2
        ;;
      --)
        shift
        REPLY_MODEL_COMMAND_EXTRA_ARGS=("$@")
        break
        ;;
      -*)
        REPLY_MODEL_COMMAND_ERROR="Unknown argument: $1"
        return 1
        ;;
      *)
        if [[ -n "$REPLY_MODEL_COMMAND_MODEL_SPEC" ]]; then
          REPLY_MODEL_COMMAND_ERROR="Unknown argument: $1"
          return 1
        fi
        REPLY_MODEL_COMMAND_MODEL_SPEC="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$REPLY_MODEL_COMMAND_MODEL_SPEC" ]]; then
    REPLY_MODEL_COMMAND_ERROR="missing model or profile name"
    return 1
  fi
}

# Resolve the model/backend/profile context shared by 'run' and 'serve'.
#
# Profile names are loaded twice on purpose:
#   1. First pass without backend filtering to read the model= line so backend
#      inference has the real HuggingFace id to inspect.
#   2. Second pass with the resolved backend to apply backend-scoped flags.
#
# Sets:
#   REPLY_MODEL_COMMAND_BACKEND      -> resolved backend (mlx or llama.cpp)
#   REPLY_MODEL_COMMAND_MODEL_SPEC   -> final HuggingFace model id, with quant if any
#   REPLY_MODEL_COMMAND_PROFILE_ARGS -> backend-filtered profile args array
_resolve_model_command_context() {
  local mode="$1"
  local backend_flag="$2"
  local model_or_profile="$3"
  local profile_name=""

  REPLY_MODEL_COMMAND_BACKEND=""
  REPLY_MODEL_COMMAND_MODEL_SPEC="$model_or_profile"
  REPLY_MODEL_COMMAND_PROFILE_ARGS=()

  # If the spec contains no '/', it cannot be a USER/MODEL HuggingFace id.
  # Treat it as a saved profile name and load its model + flags in two passes.
  if [[ "$model_or_profile" != */* ]]; then
    profile_name="$model_or_profile"
    load_profile "$profile_name" "$mode"
    REPLY_MODEL_COMMAND_MODEL_SPEC="$REPLY_PROFILE_MODEL"
  fi

  if [[ -n "$backend_flag" ]]; then
    REPLY_MODEL_COMMAND_BACKEND="$(resolve_backend "$backend_flag")"
  else
    REPLY_MODEL_COMMAND_BACKEND="$(_infer_model_backend "$REPLY_MODEL_COMMAND_MODEL_SPEC")"
  fi

  if [[ -n "$profile_name" ]]; then
    load_profile "$profile_name" "$mode" "$REPLY_MODEL_COMMAND_BACKEND"
    REPLY_MODEL_COMMAND_MODEL_SPEC="$REPLY_PROFILE_MODEL"
    REPLY_MODEL_COMMAND_PROFILE_ARGS=("${REPLY_PROFILE_ARGS[@]+"${REPLY_PROFILE_ARGS[@]}"}")
  fi
}

_cmd_run_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME run [--backend <mlx|llama.cpp>] <MODEL_NAME|PROFILE> [-- <extra args...>]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  PROFILE       A saved profile name (see: $SCRIPT_NAME list --profiles)

Options:
  --backend <backend>  Select backend: mlx or llama.cpp (default: auto-detected).

Downloads the model if needed and runs it interactively.
The backend is auto-detected with a GGUF-first heuristic: if local cache for the
model contains GGUF files, corral uses llama-cli; otherwise corral assumes mlx for
HuggingFace USER/MODEL specs. Non-HF specs fall back to platform default.
If this guess is wrong (or mlx is unsupported on your platform), use --backend
to override explicitly.

Pass additional backend-specific arguments after '--'.
Example:
  $SCRIPT_NAME run unsloth/gemma-4-E4B-it-GGUF -- -ngl 999 -c 8192
  $SCRIPT_NAME run mlx-community/Qwen3-8B-4bit
  $SCRIPT_NAME run coder
EOF
}

_cmd_run() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_run_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  if ! _parse_model_command_args "$@"; then
    echo "$REPLY_MODEL_COMMAND_ERROR" >&2
    cmd_run_usage >&2
    return 1
  fi

  local BACKEND_FLAG="$REPLY_MODEL_COMMAND_BACKEND_FLAG"
  local model_spec="$REPLY_MODEL_COMMAND_MODEL_SPEC"
  local extra_args=("${REPLY_MODEL_COMMAND_EXTRA_ARGS[@]+"${REPLY_MODEL_COMMAND_EXTRA_ARGS[@]}"}")

  _resolve_model_command_context run "$BACKEND_FLAG" "$model_spec"

  local BACKEND="$REPLY_MODEL_COMMAND_BACKEND"
  model_spec="$REPLY_MODEL_COMMAND_MODEL_SPEC"
  local profile_args=("${REPLY_MODEL_COMMAND_PROFILE_ARGS[@]+"${REPLY_MODEL_COMMAND_PROFILE_ARGS[@]}"}")

  if [[ "$BACKEND" == "mlx" ]]; then
    _run_mlx "$model_spec" "${profile_args[@]+"${profile_args[@]}"}" "${extra_args[@]+"${extra_args[@]}"}"
    return
  fi

  ensure_llama_in_path
  require_cmds llama-cli
  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local hf_args=()
  [[ -n "$hf_token" ]] && hf_args=(--hf-token "$hf_token")
  # exec replaces the shell process with llama-cli so signals and exit codes
  # flow directly to the caller without an extra wrapper layer.
  # "${arr[@]+"${arr[@]}"}" is the safe empty-array expansion idiom: without
  # the ${+...} guard, "${arr[@]}" expands to a single empty-string argument
  # when the array is empty, which would be passed to llama-cli as a flag.
  exec llama-cli -hf "$model_spec" "${hf_args[@]+"${hf_args[@]}"}" \
    "${profile_args[@]+"${profile_args[@]}"}" \
    "${extra_args[@]+"${extra_args[@]}"}"
}

# ── serve ─────────────────────────────────────────────────────────────────────

_cmd_serve_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME serve [--backend <mlx|llama.cpp>] <MODEL_NAME|PROFILE> [-- <extra args...>]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  PROFILE       A saved profile name (see: $SCRIPT_NAME list --profiles)

Options:
  --backend <backend>  Override backend: mlx or llama.cpp. Default: auto-detected.

Downloads the model if needed and serves it as an OpenAI-compatible endpoint.
The backend is auto-detected with a GGUF-first heuristic: if local cache for the
model contains GGUF files, corral uses llama-server; otherwise corral assumes mlx
for HuggingFace USER/MODEL specs. Non-HF specs fall back to platform default.
If this guess is wrong (or mlx is unsupported on your platform), use --backend
to override explicitly.

Pass additional backend-specific arguments after '--'.
Example:
  $SCRIPT_NAME serve unsloth/gemma-4-E4B-it-GGUF -- --port 8081
  $SCRIPT_NAME serve mlx-community/Qwen3-8B-4bit -- --port 8081
  $SCRIPT_NAME serve coder
EOF
}

_cmd_serve() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_serve_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  if ! _parse_model_command_args "$@"; then
    echo "$REPLY_MODEL_COMMAND_ERROR" >&2
    cmd_serve_usage >&2
    return 1
  fi

  local BACKEND_FLAG="$REPLY_MODEL_COMMAND_BACKEND_FLAG"
  local model_spec="$REPLY_MODEL_COMMAND_MODEL_SPEC"
  local extra_args=("${REPLY_MODEL_COMMAND_EXTRA_ARGS[@]+"${REPLY_MODEL_COMMAND_EXTRA_ARGS[@]}"}")

  _resolve_model_command_context serve "$BACKEND_FLAG" "$model_spec"

  local BACKEND="$REPLY_MODEL_COMMAND_BACKEND"
  model_spec="$REPLY_MODEL_COMMAND_MODEL_SPEC"
  local profile_args=("${REPLY_MODEL_COMMAND_PROFILE_ARGS[@]+"${REPLY_MODEL_COMMAND_PROFILE_ARGS[@]}"}")

  if [[ "$BACKEND" == "mlx" ]]; then
    _serve_mlx "$model_spec" "${profile_args[@]+"${profile_args[@]}"}" "${extra_args[@]+"${extra_args[@]}"}"
    return
  fi

  ensure_llama_in_path
  require_cmds llama-server
  local hf_token="${HF_TOKEN:-${HF_HUB_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}}"
  local hf_args=()
  [[ -n "$hf_token" ]] && hf_args=(--hf-token "$hf_token")
  # exec replaces the shell process with llama-server so signals and exit
  # codes flow directly to the caller. --jinja enables template-based chat.
  exec llama-server -hf "$model_spec" --jinja \
    "${hf_args[@]+"${hf_args[@]}"}" \
    "${profile_args[@]+"${profile_args[@]}"}" \
    "${extra_args[@]+"${extra_args[@]}"}"
}

# Run a model via mlx_lm.chat (MLX backend).
_run_mlx() {
  local model_spec="$1"
  shift
  local extra_args=("$@")

  require_mlx_platform
  require_mlx_lm

  # MLX models are HuggingFace model identifiers. Quant specifiers (:QUANT) are
  # llama.cpp-specific; strip them with a warning.
  if [[ "$model_spec" == *:* ]]; then
    echo "Warning: MLX backend does not use quant specifiers; ignoring ':${model_spec#*:}'." >&2
    model_spec="${model_spec%%:*}"
  fi

  # Profile names (no '/') are not supported with the MLX backend.
  if [[ "$model_spec" != */* ]]; then
    die "invalid MLX model id '${model_spec}': expected HuggingFace format USER/MODEL"
  fi

  exec mlx_lm.chat --model "$model_spec" "${extra_args[@]+"${extra_args[@]}"}"
}

# Serve a model via mlx_lm.server (MLX backend).
_serve_mlx() {
  local model_spec="$1"
  shift
  local extra_args=("$@")

  require_mlx_platform
  command -v mlx_lm.server >/dev/null 2>&1 || \
    die "mlx_lm not found. Install it first: $SCRIPT_NAME install --backend mlx"

  if [[ "$model_spec" == *:* ]]; then
    echo "Warning: MLX backend does not use quant specifiers; ignoring ':${model_spec#*:}'." >&2
    model_spec="${model_spec%%:*}"
  fi

  if [[ "$model_spec" != */* ]]; then
    die "invalid MLX model id '${model_spec}': expected HuggingFace format USER/MODEL"
  fi

  exec mlx_lm.server --model "$model_spec" "${extra_args[@]+"${extra_args[@]}"}"
}
