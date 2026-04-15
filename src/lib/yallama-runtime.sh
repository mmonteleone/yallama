# Runtime lifecycle helpers for yallama.
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

# Add the llama.cpp bin directory to the user's shell profile (fish, zsh, or
# bash) so it persists across new terminal sessions.
install_path() {
  local current_link="$1"
  local profile_mode="$2"
  local parent_shell
  parent_shell="$(basename "${SHELL:-bash}")"

  local begin_marker="# BEGIN yallama"
  local end_marker="# END yallama"
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
      mkdir -p "$(dirname "$fish_conf")"
      if ! grep -qF "$begin_marker" "$fish_conf" 2>/dev/null; then
        printf '\n%s\nfish_add_path "%s"\n%s\n' \
          "$begin_marker" "$current_link" "$end_marker" >> "$fish_conf"
        echo "Added to PATH in $fish_conf"
      else
        echo "PATH already configured in $fish_conf"
      fi
      ;;
    zsh)
      local zshrc="${ZDOTDIR:-$HOME}/.zshrc"
      if ! grep -qF "$begin_marker" "$zshrc" 2>/dev/null; then
        # shellcheck disable=SC2016  # $PATH intentionally literal in the written string
        printf '\n%s\nexport PATH="%s:$PATH"\n%s\n' \
          "$begin_marker" "$current_link" "$end_marker" >> "$zshrc"
        echo "Added to PATH in $zshrc"
      else
        echo "PATH already configured in $zshrc"
      fi
      ;;
    bash)
      local bash_conf
      # On macOS, bash reads ~/.bash_profile for login shells (the default
      # Terminal.app mode), while Linux typically uses ~/.bashrc.
      if [[ "$(uname -s)" == "Darwin" && -f "${HOME}/.bash_profile" ]]; then
        bash_conf="${HOME}/.bash_profile"
      else
        bash_conf="${HOME}/.bashrc"
      fi
      if ! grep -qF "$begin_marker" "$bash_conf" 2>/dev/null; then
        # shellcheck disable=SC2016  # $PATH intentionally literal in the written string
        printf '\n%s\nexport PATH="%s:$PATH"\n%s\n' \
          "$begin_marker" "$current_link" "$end_marker" >> "$bash_conf"
        echo "Added to PATH in $bash_conf"
      else
        echo "PATH already configured in $bash_conf"
      fi
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
Usage: $SCRIPT_NAME install [--tag <release_tag>] [--path <installation_root>] [--arch <arch>]
                           [--shell-profile | --no-shell-profile]
       $SCRIPT_NAME install --print-latest-tag

Options:
  --tag <tag>           Use a specific release tag (e.g. b5880). Defaults to latest.
  --path <dir>          Installation root. Defaults to ~/.llama.cpp.
  --arch <arch>         Asset architecture suffix (e.g. macos-arm64, macos-x86_64,
                        ubuntu-x64, ubuntu-arm64). Auto-detected if omitted.
  --shell-profile       Allow yallama to edit your shell profile for PATH/completion loading.
  --no-shell-profile    Never edit your shell profile. Default: ask if interactive, skip otherwise.
  --print-latest-tag    Print the latest release tag and exit.
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
      local dest_dir=""
      local p
      # Walk zsh's fpath array to find a writable user-owned directory for
      # completions. Falls back to ~/.zfunc if none is found.
      for p in "${fpath[@]:-}"; do
        if [[ "$p" == "${HOME}"* && -d "$p" && -w "$p" ]]; then
          dest_dir="$p"
          break
        fi
      done
      [[ -z "$dest_dir" ]] && dest_dir="${HOME}/.zfunc" && mkdir -p "$dest_dir"
      _completions_zsh > "${dest_dir}/_${SCRIPT_NAME}"
      echo "Installed zsh completions  -> ${dest_dir}/_${SCRIPT_NAME}"
      ;;
    bash)
      local dest="${HOME}/.bash_completion.d/${SCRIPT_NAME}"
      mkdir -p "${HOME}/.bash_completion.d"
      _completions_bash > "$dest"
      # shellcheck disable=SC2016  # loader is a literal string to be written into .bashrc
      local loader='for f in ~/.bash_completion.d/*; do [[ -f "$f" ]] && source "$f"; done'
      if [[ -f "${HOME}/.bashrc" ]] && ! grep -qF 'bash_completion.d' "${HOME}/.bashrc"; then
        if shell_profile_edits_allowed "$profile_mode"; then
          printf '\n# yallama shell completions\n%s\n' "$loader" >> "${HOME}/.bashrc"
        else
          echo "Bash completions installed -> $dest"
          echo "Source them manually from ${HOME}/.bashrc if you want shell completion support."
          return 0
        fi
      fi
      echo "Installed bash completions -> $dest"
      ;;
    *)
      return 0
      ;;
  esac
}

# Install or update llama.cpp from a GitHub release.
# Manages the argument-parsing loop common to all cmd_* functions:
# 'while [[ $# -gt 0 ]]; do case ... shift; done'
cmd_install() {
  require_cmds curl tar mktemp mv rm mkdir touch ln find jq basename

  local TAG=""
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local PRINT_LATEST_TAG="false"
  local ARCH=""
  local PROFILE_MODE="ask"

  while [[ $# -gt 0 ]]; do
    case "$1" in
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

  if [[ "$PRINT_LATEST_TAG" == "true" ]]; then
    if [[ -n "$TAG" || "$INSTALL_ROOT" != "$DEFAULT_INSTALL_ROOT" ]]; then
      die "--print-latest-tag cannot be combined with --tag or --path."
    fi
    local LATEST_TAG
    LATEST_TAG="$(get_latest_tag)"
    [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && die "failed to determine latest release tag."
    printf '%s\n' "$LATEST_TAG"
    return 0
  fi

  [[ -z "$ARCH" ]] && ARCH="$(detect_arch)"

  # ${INSTALL_ROOT/#\~/$HOME}: expand leading tilde. See ensure_llama_in_path.
  # ${INSTALL_ROOT%/}: strip trailing slash for consistent path joining.
  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

  _do_install "$TAG" "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
}

cmd_update_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME update [--path <installation_root>] [--arch <arch>]
                          [--shell-profile | --no-shell-profile]

Options:
  --path <dir>    Installation root. Defaults to ~/.llama.cpp.
  --arch <arch>   Asset architecture suffix. Auto-detected if omitted.
  --shell-profile Allow yallama to edit your shell profile for PATH/completion loading.
  --no-shell-profile
                  Never edit your shell profile. Default: ask if interactive, skip otherwise.

Checks whether a newer release exists and installs it if so.
EOF
}

cmd_update() {
  require_cmds curl jq

  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local ARCH=""
  local PROFILE_MODE="ask"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      --arch)    ARCH="${2:-}"; shift 2 ;;
      --shell-profile)    PROFILE_MODE="always"; shift ;;
      --no-shell-profile) PROFILE_MODE="never"; shift ;;
      -h|--help) cmd_update_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_update_usage >&2; return 1 ;;
    esac
  done

  [[ -z "$ARCH" ]] && ARCH="$(detect_arch)"
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

  echo "Checking for latest release..."
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
    echo "No existing installation found. Installing ${LATEST_TAG}..."
  fi

  require_cmds curl tar mktemp mv rm mkdir touch ln find basename
  _do_install "$LATEST_TAG" "$INSTALL_ROOT" "$ARCH" "$PROFILE_MODE"
}

cmd_status_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME status [--path <installation_root>] [--check-update]

Options:
  --path <dir>      Installation root. Defaults to ~/.llama.cpp.
  --check-update    Also query GitHub for the latest available release tag.
EOF
}

cmd_status() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local CHECK_UPDATE="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)          INSTALL_ROOT="${2:-}"; shift 2 ;;
      --check-update)  CHECK_UPDATE="true"; shift ;;
      -h|--help)       cmd_status_usage; return 0 ;;
      *)               echo "Unknown argument: $1" >&2; cmd_status_usage >&2; return 1 ;;
    esac
  done

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

  local CURRENT_LINK="${INSTALL_ROOT}/current"

  # Check both -L (symlink) and -d (directory): the current link should be
  # a symlink, but also handle edge cases where it was replaced with a directory.
  if [[ ! -L "$CURRENT_LINK" && ! -d "$CURRENT_LINK" ]]; then
    echo "llama.cpp: not installed (${INSTALL_ROOT})"
    return 0
  fi

  local INSTALLED_TAG=""
  if [[ -L "$CURRENT_LINK" ]]; then
    # Extract the version tag from the symlink target's directory name.
    INSTALLED_TAG="$(basename "$(readlink "$CURRENT_LINK")")"
    INSTALLED_TAG="${INSTALLED_TAG#llama-}"
  fi

  echo "Installed : ${INSTALLED_TAG:-unknown}"
  echo "Location  : $CURRENT_LINK"

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

cmd_uninstall_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME uninstall [--path <installation_root>] [--delete-hf-cache] [--self] [--force]

Options:
  --path <dir>          Installation root. Defaults to ~/.llama.cpp.
  --delete-hf-cache    Also delete cached model directories under ~/.cache/huggingface/hub.
  --self               Also delete the yallama script itself.
  --force              Skip confirmation prompts.
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

cmd_uninstall() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local DELETE_HF_CACHE="false"
  local DELETE_SELF="false"
  local FORCE="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
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

cmd_versions_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME versions [--path <installation_root>]

Lists all installed llama.cpp versions under the installation root.
The currently active version is marked with (current).

Options:
  --path <dir>   Installation root. Defaults to ~/.llama.cpp.
EOF
}

cmd_versions() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      -h|--help) cmd_versions_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_versions_usage >&2; return 1 ;;
    esac
  done

  INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
  INSTALL_ROOT="${INSTALL_ROOT%/}"

  if [[ ! -d "$INSTALL_ROOT" ]]; then
    echo "No llama.cpp installation found at: $INSTALL_ROOT"
    return 0
  fi

  local current_link="${INSTALL_ROOT}/current"
  local current_dir=""
  if [[ -L "$current_link" ]]; then
    current_dir="$(readlink "$current_link")"
    # If the readlink result is relative, make it absolute by prepending INSTALL_ROOT.
    [[ "$current_dir" != /* ]] && current_dir="${INSTALL_ROOT}/${current_dir}"
  fi

  local found=0
  local dir
  for dir in "$INSTALL_ROOT"/llama-*/; do
    # Glob may match literally "llama-*/" if no directories exist; skip non-dirs.
    [[ -d "$dir" ]] || continue
    if [[ "$found" -eq 0 ]]; then
      printf '%-20s  %s\n' 'VERSION' 'STATUS'
      printf '%-20s  %s\n' '-------' '------'
    fi
    found=1
    local tag
    tag="$(basename "$dir")"
    # ${tag#llama-}: strip the "llama-" prefix, leaving just the version tag.
    tag="${tag#llama-}"
    local dir_abs="${dir%/}"
    if [[ "$dir_abs" == "$current_dir" ]]; then
      printf '%-20s  %s\n' "$tag" 'current'
    else
      printf '%-20s  %s\n' "$tag" '-'
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    echo "No llama.cpp versions installed at: $INSTALL_ROOT"
  fi
}

cmd_prune_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME prune [--path <installation_root>] [--force]

Removes all installed llama.cpp versions except the currently active one.

Options:
  --path <dir>   Installation root. Defaults to ~/.llama.cpp.
  --force        Skip confirmation prompt.
EOF
}

cmd_prune() {
  local INSTALL_ROOT="$DEFAULT_INSTALL_ROOT"
  local FORCE="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --path)    INSTALL_ROOT="${2:-}"; shift 2 ;;
      --force)   FORCE="true"; shift ;;
      -h|--help) cmd_prune_usage; return 0 ;;
      *)         echo "Unknown argument: $1" >&2; cmd_prune_usage >&2; return 1 ;;
    esac
  done

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
Usage: $SCRIPT_NAME pull <MODEL_NAME[:QUANT]>

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  QUANT         Optional quant tag to download a specific variant (e.g. Q4_K_M, UD-Q6_K).

Downloads (pre-warms) a HuggingFace model into the local cache without running it.
EOF
}

cmd_pull() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_pull_usage
    [[ $# -eq 0 ]] && return 1 || return 0
  fi

  local model_spec="$1"
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

# ── run ───────────────────────────────────────────────────────────────────────

cmd_run_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME run <MODEL_NAME|PROFILE> [-- <llama-cli args...>]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  PROFILE       A saved profile name (see: $SCRIPT_NAME profile list)

Downloads the model if needed and runs it interactively via llama-cli.
When a profile is given, its model and flags are used automatically.

Pass additional llama-cli arguments after '--'. These are appended after any
profile flags and will override profile flags when the same flag appears twice.
Example:
  $SCRIPT_NAME run unsloth/gemma-4-E4B-it-GGUF -- -ngl 999 -c 8192
  $SCRIPT_NAME run coder
  $SCRIPT_NAME run coder -- --temp 0.5
EOF
}

cmd_run() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_run_usage
    [[ $# -eq 0 ]] && return 1 || return 0
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
  local profile_args=()
  if [[ "$model_spec" != */* ]]; then
    _load_profile "$model_spec" run
    model_spec="$REPLY_PROFILE_MODEL"
    profile_args=("${REPLY_PROFILE_ARGS[@]+"${REPLY_PROFILE_ARGS[@]}"}")
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
Usage: $SCRIPT_NAME serve <MODEL_NAME|PROFILE> [-- <llama-server args...>]

Arguments:
  MODEL_NAME    HuggingFace model identifier, e.g. unsloth/gemma-4-26B-A4B-it-GGUF
  PROFILE       A saved profile name (see: $SCRIPT_NAME profile list)

Downloads the model if needed and serves it via llama-server with Jinja templates.
When a profile is given, its model and flags are used automatically.

Pass additional llama-server arguments after '--'. These are appended after any
profile flags and will override profile flags when the same flag appears twice.
Example:
  $SCRIPT_NAME serve unsloth/gemma-4-E4B-it-GGUF -- --port 8081
  $SCRIPT_NAME serve coder
  $SCRIPT_NAME serve coder -- --port 8081
EOF
}

cmd_serve() {
  if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
    cmd_serve_usage
    [[ $# -eq 0 ]] && return 1 || return 0
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
  local profile_args=()
  if [[ "$model_spec" != */* ]]; then
    _load_profile "$model_spec" serve
    model_spec="$REPLY_PROFILE_MODEL"
    profile_args=("${REPLY_PROFILE_ARGS[@]+"${REPLY_PROFILE_ARGS[@]}"}")
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

cmd_ps() {
  local ps_output
  # Try GNU/Linux ps format first (-eo); fall back to BSD/macOS (-ax -o).
  # The awk script filters to llama-cli and llama-server process names only.
  # Matching on full args can self-match the awk command line itself.
  ps_output="$({ ps -eo pid=,comm=,args= -ww 2>/dev/null || ps -ax -o pid=,comm=,args= -ww 2>/dev/null; } | awk '
    {
      pid = $1
      proc = $2

      if (proc !~ /^llama-(cli|server)$/) {
        next
      }

      model = "(unknown)"
      port = "-"

      for (i = 3; i <= NF; i++) {
        if (($i == "-hf" || $i == "--hf") && i < NF) {
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
      if (proc != "llama-server") {
        port = "-"
      } else if (port == "-") {
        # llama-server defaults to port 8080 when --port is not explicitly given.
        port = "8080"
      }

      printf "%s\t%s\t%s\t%s\n", pid, proc, port, model
    }
  ')"

  if [[ -z "$ps_output" ]]; then
    echo "No llama-cli or llama-server processes running."
    return 0
  fi

  printf '%-8s  %-14s  %-10s  %s\n' 'PID' 'PROCESS' 'PORT' 'MODEL'
  printf '%-8s  %-14s  %-10s  %s\n' '---' '-------' '----' '-----'

  # IFS=$'\t': use tab as the field separator for read, matching the
  # tab-delimited output from the awk script above.
  while IFS=$'\t' read -r pid proc port model; do
    printf '%-8s  %-14s  %-10s  %s\n' "$pid" "$proc" "$port" "$model"
  done <<< "$ps_output"
}
