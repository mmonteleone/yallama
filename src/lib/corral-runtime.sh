# Runtime lifecycle helpers for corral.
# shellcheck shell=bash

# macOS Gatekeeper places a quarantine extended attribute on files downloaded
# from the internet, blocking execution until the user approves them in System
# Settings. Strip the attribute here so freshly downloaded llama.cpp binaries
# run without a Gatekeeper popup. No-ops on non-Darwin systems.
clear_macos_quarantine() {
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
detect_arch() {
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
github_get() {
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

# Fetch the release JSON for a given tag, or the latest release if tag is empty.
get_release_json() {
  local tag="$1"
  if [[ -n "$tag" ]]; then
    github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${tag}"
  else
    github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
  fi
}

# Return just the tag name string of the latest llama.cpp release.
# 'jq -r' outputs the raw string without JSON quotes.
get_latest_tag() {
  get_release_json "" | jq -r '.tag_name'
}

# Escape a string for safe inclusion inside a double-quoted shell config line.
# Newlines are rejected because they would corrupt the managed config block.
_escape_double_quoted_string() {
  local value="$1"

  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    die "shell profile values cannot contain newlines"
  fi

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '%s' "$value"
}

# Return the bash startup file corral should manage on this platform.
_bash_startup_file() {
  if [[ "$(uname -s)" == "Darwin" && -f "${HOME}/.bash_profile" ]]; then
    printf '%s' "${HOME}/.bash_profile"
  else
    printf '%s' "${HOME}/.bashrc"
  fi
}

_zsh_startup_file() {
  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc"
}

_zsh_completions_dir() {
  printf '%s' "${ZDOTDIR:-$HOME}/.zfunc"
}

# Replace or append a managed block inside a shell config file.
_upsert_managed_block() {
  local file_path="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local block_body="$4"
  local tmp_file
  local wrote_block="false"
  local inside_block="false"
  local line

  mkdir -p "$(dirname "$file_path")"
  touch "$file_path"
  tmp_file="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$inside_block" == "true" ]]; then
      if [[ "$line" == "$end_marker" ]]; then
        inside_block="false"
      fi
      continue
    fi

    if [[ "$line" == "$begin_marker" ]]; then
      if [[ "$wrote_block" == "false" ]]; then
        printf '%s\n%s\n%s\n' "$begin_marker" "$block_body" "$end_marker" >> "$tmp_file"
        wrote_block="true"
      fi
      inside_block="true"
      continue
    fi

    printf '%s\n' "$line" >> "$tmp_file"
  done < "$file_path"

  if [[ "$wrote_block" == "false" ]]; then
    [[ -s "$tmp_file" ]] && printf '\n' >> "$tmp_file"
    printf '%s\n%s\n%s\n' "$begin_marker" "$block_body" "$end_marker" >> "$tmp_file"
  fi

  mv "$tmp_file" "$file_path"
}

# Add the llama.cpp bin directory to the user's shell profile (fish, zsh, or
# bash) so it persists across new terminal sessions.
install_path() {
  local current_link="$1"
  local profile_mode="$2"
  local parent_shell
  local escaped_current_link
  parent_shell="$(basename "${SHELL:-bash}")"
  escaped_current_link="$(_escape_double_quoted_string "$current_link")"

  local begin_marker="# BEGIN corral"
  local end_marker="# END corral"
  # The BEGIN/END sentinel lines make the PATH addition idempotent:
  # re-running install will not append a duplicate entry to the shell profile.

  if ! shell_profile_edits_allowed "$profile_mode"; then
    echo "Skipping shell profile edits. Add this to your PATH manually:"
    echo "  $current_link"
    return 0
  fi

  case "$parent_shell" in
    fish)
      local fish_conf="${HOME}/.config/fish/config.fish"
      _upsert_managed_block "$fish_conf" "$begin_marker" "$end_marker" "fish_add_path \"$escaped_current_link\""
      echo "Configured PATH in $fish_conf"
      ;;
    zsh)
      local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
      _upsert_managed_block "$zshrc" "$begin_marker" "$end_marker" "export PATH=\"$escaped_current_link:\$PATH\""
      echo "Configured PATH in $zshrc"
      ;;
    bash)
      local bash_conf
      bash_conf="$(_bash_startup_file)"
      _upsert_managed_block "$bash_conf" "$begin_marker" "$end_marker" "export PATH=\"$escaped_current_link:\$PATH\""
      echo "Configured PATH in $bash_conf"
      ;;
    *)
      echo
      echo "Add this to your PATH:"
      echo "  $current_link"
      ;;
  esac
}

cmd_install_usage() {
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

  local ASSET_NAME="llama-${TAG}-bin-${ARCH}.tar.gz"
  local RELEASE_JSON
  echo "Fetching release metadata..."
  RELEASE_JSON="$(get_release_json "$TAG")"

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

  clear_macos_quarantine "$STAGED_TARGET"

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

install_completions() {
  local profile_mode="$1"

  local parent_shell
  parent_shell="$(basename "${SHELL:-bash}")"

  case "$parent_shell" in
    fish)
      local dest_dir="${HOME}/.config/fish/completions"
      mkdir -p "$dest_dir"
      _completions_fish > "${dest_dir}/${SCRIPT_NAME}.fish"
      echo "Installed fish completions -> ${dest_dir}/${SCRIPT_NAME}.fish"
      ;;
    zsh)
      local dest_dir
      local zshrc
      local loader_begin="# BEGIN corral zsh completions"
      local loader_end="# END corral zsh completions"
      local escaped_dest_dir
      local loader_body
      dest_dir="$(_zsh_completions_dir)"
      zshrc="$(_zsh_startup_file)"
      escaped_dest_dir="$(_escape_double_quoted_string "$dest_dir")"
      mkdir -p "$dest_dir"
      _completions_zsh > "${dest_dir}/_${SCRIPT_NAME}"
      loader_body="$(cat <<EOF
if (( \${fpath[(Ie)"$escaped_dest_dir"]} == 0 )); then
  fpath=("$escaped_dest_dir" \$fpath)
fi
if (( ! \$+functions[compdef] )); then
  autoload -Uz compinit
  compinit
fi
EOF
)"
      if shell_profile_edits_allowed "$profile_mode"; then
        _upsert_managed_block "$zshrc" "$loader_begin" "$loader_end" "$loader_body"
        echo "Configured zsh completions loader in $zshrc"
      else
        echo "Zsh completions installed -> ${dest_dir}/_${SCRIPT_NAME}"
        echo "Add $dest_dir to fpath and run compinit from $zshrc to enable them."
        return 0
      fi
      echo "Installed zsh completions  -> ${dest_dir}/_${SCRIPT_NAME}"
      ;;
    bash)
      local dest="${HOME}/.bash_completion.d/${SCRIPT_NAME}"
      local bash_conf
      local loader_begin="# BEGIN corral bash completions"
      local loader_end="# END corral bash completions"
      local loader_body
      mkdir -p "${HOME}/.bash_completion.d"
      _completions_bash > "$dest"
      bash_conf="$(_bash_startup_file)"
      loader_body="# corral shell completions"$'\n'"for f in ~/.bash_completion.d/*; do [[ -f \"\$f\" ]] && source \"\$f\"; done"
      if shell_profile_edits_allowed "$profile_mode"; then
        _upsert_managed_block "$bash_conf" "$loader_begin" "$loader_end" "$loader_body"
        echo "Configured bash completions loader in $bash_conf"
      else
        echo "Bash completions installed -> $dest"
        echo "Source them manually from $bash_conf if you want shell completion support."
        return 0
      fi
      echo "Installed bash completions -> $dest"
      ;;
    *)
      return 0
      ;;
  esac
}

# Non-fatal mlx-lm install. Like _do_install_mlx but warns and returns 0
# instead of dying when prerequisites (uv) remain unavailable.
# Used by the combined (all-backends) install path.
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
cmd_install() {
  local TAG=""
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local PRINT_LATEST_TAG="false"
  local ARCH=""
  local PROFILE_MODE="ask"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)           BACKEND_FLAG="${2:-}"; shift 2 ;;
      --tag)               TAG="${2:-}"; shift 2 ;;
      --path)              INSTALL_ROOT="${2:-}"; shift 2 ;;
      --arch)              ARCH="${2:-}"; shift 2 ;;
      --shell-profile)     PROFILE_MODE="always"; shift ;;
      --no-shell-profile)  PROFILE_MODE="never"; shift ;;
      --print-latest-tag)  PRINT_LATEST_TAG="true"; shift ;;
      -h|--help)           cmd_install_usage; return 0 ;;
      *)                   echo "Unknown argument: $1" >&2; cmd_install_usage >&2; return 1 ;;
    esac
  done

  # Validate --backend if provided.
  if [[ -n "$BACKEND_FLAG" ]]; then
    case "$BACKEND_FLAG" in
      mlx|llama.cpp) ;;
      *) die "unknown backend '${BACKEND_FLAG}': must be 'mlx' or 'llama.cpp'" ;;
    esac
  fi

  # --backend mlx: install only mlx.
  if [[ "$BACKEND_FLAG" == "mlx" ]]; then
    _do_install_mlx
    install_completions "$PROFILE_MODE" || true
    return 0
  fi

  # --print-latest-tag is llama.cpp-only.
  if [[ "$PRINT_LATEST_TAG" == "true" ]]; then
    if [[ -n "$TAG" || "$INSTALL_ROOT" != "$DEFAULT_INSTALL_ROOT" ]]; then
      die "--print-latest-tag cannot be combined with --tag or --path."
    fi
    require_cmds curl jq
    local LATEST_TAG
    LATEST_TAG="$(get_latest_tag)"
    [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && die "failed to determine latest release tag."
    printf '%s\n' "$LATEST_TAG"
    return 0
  fi

  # --backend llama.cpp or combined: install llama.cpp.
  require_cmds curl tar mktemp mv rm mkdir touch ln find jq basename

  [[ -z "$ARCH" ]] && ARCH="$(detect_arch)"

  # ${INSTALL_ROOT/#\~/$HOME}: expand leading tilde. See ensure_llama_in_path.
  # ${INSTALL_ROOT%/}: strip trailing slash for consistent path joining.
  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

  _do_install "$TAG" "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"

  # When only llama.cpp was requested, stop here.
  [[ "$BACKEND_FLAG" == "llama.cpp" ]] && return 0

  # Combined path (no --backend): also install mlx if on Apple Silicon.
  if _is_mlx_platform; then
    echo
    echo "Installing MLX backend..."
    _try_install_mlx
  fi
}

cmd_update_usage() {
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

# Non-fatal mlx update. Unlike _update_mlx, warns and returns 0 instead of dying
# when mlx-lm is not installed or uv is unavailable.
# Used by the combined (all-backends) update path.
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

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

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
  LATEST_TAG="$(get_latest_tag)"
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

cmd_update() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local ARCH=""
  local PROFILE_MODE="ask"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND_FLAG="${2:-}"; shift 2 ;;
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      --arch)    ARCH="${2:-}"; shift 2 ;;
      --shell-profile)    PROFILE_MODE="always"; shift ;;
      --no-shell-profile) PROFILE_MODE="never"; shift ;;
      -h|--help) cmd_update_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_update_usage >&2; return 1 ;;
    esac
  done

  # Validate --backend if provided.
  if [[ -n "$BACKEND_FLAG" ]]; then
    case "$BACKEND_FLAG" in
      mlx|llama.cpp) ;;
      *) die "unknown backend '${BACKEND_FLAG}': must be 'mlx' or 'llama.cpp'" ;;
    esac
  fi

  if [[ "$BACKEND_FLAG" == "mlx" ]]; then
    _update_mlx
    return 0
  fi

  require_cmds curl jq
  [[ -z "$ARCH" ]] && ARCH="$(detect_arch)"

  if [[ "$BACKEND_FLAG" == "llama.cpp" ]]; then
    _update_llama "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
    return 0
  fi

  # Combined path (no --backend): update llama.cpp and mlx if on Apple Silicon.
  _update_llama "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
  if _is_mlx_platform; then
    echo
    _try_update_mlx
  fi
}

cmd_status_usage() {
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

cmd_status() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local CHECK_UPDATE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)          INSTALL_ROOT="${2:-}"; shift 2 ;;
      --check-update)  CHECK_UPDATE="true"; shift ;;
      --backend)       BACKEND_FLAG="${2:-}"; shift 2 ;;
      -h|--help)       cmd_status_usage; return 0 ;;
      *)               echo "Unknown argument: $1" >&2; cmd_status_usage >&2; return 1 ;;
    esac
  done

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

  echo "Platform  : $(uname -s)/$(uname -m)"

  if [[ -n "$BACKEND_FLAG" ]]; then
    local BACKEND
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
    echo "Backend   : $BACKEND"
    echo
    if [[ "$BACKEND" == "mlx" ]]; then
      _status_mlx
    else
      _status_llama "$INSTALL_ROOT" "$CHECK_UPDATE"
    fi
    return 0
  fi

  # Combined path (no --backend): show all supported backends.
  echo
  _status_llama "$INSTALL_ROOT" "$CHECK_UPDATE"

  if _is_mlx_platform; then
    echo
    _status_mlx
  fi
}

# Print llama.cpp installation status.
_status_llama() {
  local INSTALL_ROOT="$1"
  local CHECK_UPDATE="$2"
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
    LATEST_TAG="$(get_latest_tag)"
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
  if command -v mlx_lm.generate >/dev/null 2>&1; then
    local version
    version="$(_mlx_lm_version)"
    echo "mlx-lm    : installed (${version})"
  else
    echo "mlx-lm    : not installed (run: $SCRIPT_NAME install --backend mlx)"
  fi
}

cmd_uninstall_usage() {
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

delete_hf_model_cache_dirs() {
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

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

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
    delete_hf_model_cache_dirs
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

cmd_uninstall() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local DELETE_HF_CACHE="false"
  local DELETE_SELF="false"
  local FORCE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)          BACKEND_FLAG="${2:-}"; shift 2 ;;
      --path)             INSTALL_ROOT="${2:-}"; shift 2 ;;
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

  # Validate --backend if provided.
  if [[ -n "$BACKEND_FLAG" ]]; then
    case "$BACKEND_FLAG" in
      mlx|llama.cpp) ;;
      *) die "unknown backend '${BACKEND_FLAG}': must be 'mlx' or 'llama.cpp'" ;;
    esac
  fi

  if [[ "$BACKEND_FLAG" == "mlx" ]]; then
    _uninstall_mlx_components "$FORCE" || return 1
    _uninstall_shared_options "$DELETE_HF_CACHE" "$DELETE_SELF" "$FORCE"
    return 0
  fi

  if [[ "$BACKEND_FLAG" == "llama.cpp" ]]; then
    _uninstall_llama_components "$INSTALL_ROOT" "$FORCE" || return 1
    _uninstall_shared_options "$DELETE_HF_CACHE" "$DELETE_SELF" "$FORCE"
    return 0
  fi

  # Combined path (no --backend): uninstall all supported backends.
  if _is_mlx_platform; then
    echo "--- MLX backend ---"
    _uninstall_mlx_components "$FORCE" || return 1
    echo
  fi

  echo "--- llama.cpp backend ---"
  _uninstall_llama_components "$INSTALL_ROOT" "$FORCE" || return 1

  # Shared options run once regardless of how many backends were uninstalled.
  _uninstall_shared_options "$DELETE_HF_CACHE" "$DELETE_SELF" "$FORCE"
}

cmd_versions_usage() {
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
  root="${root/#\~/$HOME}"
  root="${root%/}"

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

cmd_versions() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND_FLAG="${2:-}"; shift 2 ;;
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      -h|--help) cmd_versions_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_versions_usage >&2; return 1 ;;
    esac
  done

  # Validate --backend if provided.
  if [[ -n "$BACKEND_FLAG" ]]; then
    case "$BACKEND_FLAG" in
      mlx|llama.cpp) ;;
      *) die "unknown backend '${BACKEND_FLAG}': must be 'mlx' or 'llama.cpp'" ;;
    esac
  fi

  if [[ "$BACKEND_FLAG" == "mlx" ]]; then
    _emit_mlx_version_rows | _print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
    return 0
  fi

  if [[ "$BACKEND_FLAG" == "llama.cpp" ]]; then
    _emit_llama_version_rows "$INSTALL_ROOT" | _print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
    return 0
  fi

  # Combined path (no --backend): show all installed backends.
  {
    _emit_llama_version_rows "$INSTALL_ROOT"

    if _is_mlx_platform; then
      _emit_mlx_version_rows
    fi
  } | _print_tsv_table 'lll' $'TYPE\tVERSION\tSTATUS'
}

cmd_prune_usage() {
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

cmd_prune() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local FORCE="false"
  local BACKEND_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) BACKEND_FLAG="${2:-}"; shift 2 ;;
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      --force)   FORCE="true"; shift ;;
      -h|--help) cmd_prune_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_prune_usage >&2; return 1 ;;
    esac
  done

  local BACKEND="llama.cpp"
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  fi

  if [[ "$BACKEND" == "mlx" ]]; then
    echo "Nothing to prune for MLX. 'prune' only removes old llama.cpp installs."
    return 0
  fi

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

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

cmd_pull_usage() {
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

cmd_pull() {
  if [[ $# -eq 0 ]]; then
    cmd_pull_usage
    return 1
  fi

  local BACKEND_FLAG=""
  local model_spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend)
        if [[ $# -lt 2 ]]; then
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

  _parse_model_spec "$model_spec"
  local model_name="$REPLY_MODEL"
  local quant="$REPLY_QUANT"
  local cache_dir
  cache_dir="$(model_name_to_cache_dir "$model_name")"
  ensure_llama_in_path
  require_cmds llama-cli

  if cache_has_model_or_quant "$cache_dir" "$quant"; then
    echo "Model already cached: $model_spec"
    echo "  $cache_dir"
    return 0
  fi

  echo "Pulling model: $model_spec"
  # Force a non-conversation single turn with a non-empty placeholder prompt so
  # llama-cli downloads into the HF cache and exits instead of entering chat
  # mode on models that advertise a chat template by default.
  # Invoke llama-cli just long enough to warm the HF cache, then exit:
  # --no-conversation --single-turn: one-shot mode so the process exits after one pass.
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
  llama-cli -hf "$model_spec" "${hf_args[@]+"${hf_args[@]}"}" --no-conversation --single-turn --prompt ' ' --no-display-prompt -n 0 </dev/null || pull_status=$?

  if cache_has_model_or_quant "$cache_dir" "$quant"; then
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

# Infer the backend for 'pull' from the model spec alone (nothing is cached yet).
# - repo name ends in -GGUF (case-insensitive) → llama.cpp
# - otherwise → platform default
# Note: this differs from _infer_model_backend, which assumes 'mlx' for any
# USER/MODEL spec without GGUF evidence. For pull we use the platform default
# so that tests on non-arm64 platforms get llama.cpp for ambiguous model names.
_infer_pull_backend() {
  local model_spec="$1"
  local model_name="${model_spec%%:*}"
  if [[ "$model_name" =~ -[Gg][Gg][Uu][Ff]$ ]]; then
    printf 'llama.cpp'
  else
    _platform_default_backend
  fi
}

# Pull a model via mlx_lm.generate (MLX backend).
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

# Infer the backend required for a model spec based on local evidence.
# 1. If the model has GGUF files in the HF cache → llama.cpp
# 2. Otherwise, for HuggingFace USER/MODEL specs, assume mlx.
# 3. For non-HF specs, fall back to the platform default.
# Use --backend to override when the heuristic is wrong.
_infer_model_backend() {
  local model_spec="$1"
  # Strip quant spec: "user/model:Q4_K_M" → "user/model"
  local model_name="${model_spec%%:*}"

  # Only check cache for valid USER/MODEL specs (contain a '/').
  if [[ "$model_name" == */* ]]; then
    # Check for GGUF files in the local HF cache.
    local cache_dir
    cache_dir="$(model_name_to_cache_dir "$model_name" 2>/dev/null || true)"
    if [[ -n "$cache_dir" && -d "$cache_dir" ]] && _cache_dir_has_gguf "$cache_dir"; then
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
  _platform_default_backend
}

cmd_run_usage() {
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

cmd_run() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_run_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local BACKEND_FLAG=""
  if [[ "$1" == "--backend" ]]; then
    BACKEND_FLAG="${2:-}"
    shift 2
    if [[ $# -eq 0 ]]; then
      cmd_run_usage >&2
      return 1
    fi
  fi

  local model_spec="$1"
  shift
  local extra_args=()
  if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--" ]]; then
      echo "Unknown argument: $1" >&2
      cmd_run_usage >&2
      return 1
    fi
    shift
    extra_args=("$@")
  fi

  # If the spec contains no '/', it cannot be a "USER/MODEL" HuggingFace id.
  # Treat it as a saved profile name and load its model and flags.
  local profile_name=""
  local profile_args=()
  if [[ "$model_spec" != */* ]]; then
    profile_name="$model_spec"
    # First pass: extract the model spec to determine the backend.
    _load_profile "$profile_name" run
    model_spec="$REPLY_PROFILE_MODEL"
  fi

  # Resolve backend: explicit flag > infer from model spec.
  local BACKEND
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  else
    BACKEND="$(_infer_model_backend "$model_spec")"
  fi

  # Second pass: reload the profile with backend filtering if applicable.
  if [[ -n "$profile_name" ]]; then
    _load_profile "$profile_name" run "$BACKEND"
    model_spec="$REPLY_PROFILE_MODEL"
    profile_args=("${REPLY_PROFILE_ARGS[@]+"${REPLY_PROFILE_ARGS[@]}"}")
  fi

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

cmd_serve_usage() {
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

cmd_serve() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_serve_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local BACKEND_FLAG=""
  if [[ "$1" == "--backend" ]]; then
    BACKEND_FLAG="${2:-}"
    shift 2
    if [[ $# -eq 0 ]]; then
      cmd_serve_usage >&2
      return 1
    fi
  fi

  local model_spec="$1"
  shift
  local extra_args=()
  if [[ $# -gt 0 ]]; then
    if [[ "$1" != "--" ]]; then
      echo "Unknown argument: $1" >&2
      cmd_serve_usage >&2
      return 1
    fi
    shift
    extra_args=("$@")
  fi

  # If the spec contains no '/', it cannot be a "USER/MODEL" HuggingFace id.
  # Treat it as a saved profile name and load its model and flags.
  local profile_name=""
  local profile_args=()
  if [[ "$model_spec" != */* ]]; then
    profile_name="$model_spec"
    # First pass: extract the model spec to determine the backend.
    _load_profile "$profile_name" serve
    model_spec="$REPLY_PROFILE_MODEL"
  fi

  # Resolve backend: explicit flag > infer from model spec.
  local BACKEND
  if [[ -n "$BACKEND_FLAG" ]]; then
    BACKEND="$(resolve_backend "$BACKEND_FLAG")"
  else
    BACKEND="$(_infer_model_backend "$model_spec")"
  fi

  # Second pass: reload the profile with backend filtering if applicable.
  if [[ -n "$profile_name" ]]; then
    _load_profile "$profile_name" serve "$BACKEND"
    model_spec="$REPLY_PROFILE_MODEL"
    profile_args=("${REPLY_PROFILE_ARGS[@]+"${REPLY_PROFILE_ARGS[@]}"}")
  fi

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

# ── ps ────────────────────────────────────────────────────────────────────────

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

cmd_ps() {
  local ps_output
  # Try GNU/Linux ps format first (-eo); fall back to BSD/macOS (-ax -o).
  # Detect target processes from the command name or early executable/script
  # tokens in args. Limiting fallback to the first command-like fields avoids
  # self-matching awk script text that may mention llama/port flags.
  ps_output="$({ ps -eo pid=,comm=,args= -ww 2>/dev/null || ps -ax -o pid=,comm=,args= -ww 2>/dev/null; } | awk '
    {
      pid = $1
      proc = $2
      matched = ""

      if (proc ~ /^llama-(cli|server)$/ || proc == "mlx_lm.server" || proc == "mlx_lm.chat") {
        matched = proc
      } else {
        for (i = 3; i <= NF && i <= 4; i++) {
          if ($i ~ /^-/) {
            break
          }

          token = $i
          sub(/^.*\//, "", token)

          if (token ~ /^llama-(cli|server)$/ || token == "mlx_lm.server" || token == "mlx_lm.chat") {
            matched = token
            break
          }
        }
      }

      if (matched == "") {
        next
      }

      proc = matched

      model = "(unknown)"
      port = "-"

      for (i = 3; i <= NF; i++) {
        if (($i == "-hf" || $i == "--hf" || $i == "--model") && i < NF) {
          model = $(i + 1)
        } else if (($i == "-p" || $i == "--port") && i < NF) {
          port = $(i + 1)
        } else if ($i ~ /^--port=/) {
          split($i, parts, "=")
          port = parts[2]
        } else if ($i ~ /^-p[0-9]+$/) {
          port = substr($i, 3)
        }
      }

      sub(/^.*\//, "", proc)
      if (proc != "llama-server" && proc != "mlx_lm.server") {
        port = "-"
      } else if (port == "-") {
        # llama-server and mlx_lm.server default to port 8080 when --port is not explicitly given.
        port = "8080"
      }

      printf "%s\t%s\t%s\t%s\n", pid, proc, port, model
    }
  ')"

  if [[ -z "$ps_output" ]]; then
    echo "No llama-cli, llama-server, mlx_lm.chat, or mlx_lm.server processes running."
    return 0
  fi

  _print_tsv_table 'llll' $'PID\tPROCESS\tPORT\tMODEL' <<< "$ps_output"
}
