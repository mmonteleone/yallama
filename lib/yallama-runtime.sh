# Runtime lifecycle helpers for yallama.

clear_macos_quarantine() {
  local target="$1"

  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v xattr >/dev/null 2>&1 || return 0

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

get_release_json() {
  local tag="$1"
  if [[ -n "$tag" ]]; then
    github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/${tag}"
  else
    github_get "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
  fi
}

get_latest_tag() {
  get_release_json "" | jq -r '.tag_name'
}

install_path() {
  local current_link="$1"
  local profile_mode="$2"
  local parent_shell
  parent_shell="$(basename "${SHELL:-bash}")"

  local begin_marker="# BEGIN yallama"
  local end_marker="# END yallama"

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
        printf '\n%s\nexport PATH="%s:$PATH"\n%s\n' \
          "$begin_marker" "$current_link" "$end_marker" >> "$zshrc"
        echo "Added to PATH in $zshrc"
      else
        echo "PATH already configured in $zshrc"
      fi
      ;;
    bash)
      local bash_conf
      if [[ "$(uname -s)" == "Darwin" && -f "${HOME}/.bash_profile" ]]; then
        bash_conf="${HOME}/.bash_profile"
      else
        bash_conf="${HOME}/.bashrc"
      fi
      if ! grep -qF "$begin_marker" "$bash_conf" 2>/dev/null; then
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

  if [[ -z "$TAG" || "$TAG" == "null" ]]; then
    TAG="$(jq -r '.tag_name' <<<"$RELEASE_JSON")"
    [[ -z "$TAG" || "$TAG" == "null" ]] && die "failed to determine latest release tag."
    ASSET_NAME="llama-${TAG}-bin-${ARCH}.tar.gz"
  fi

  local ASSET_URL
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
  local MARKER_FILE="${TARGET_DIR}/.install-complete"
  local CURRENT_LINK="${INSTALL_ROOT}/current"

  mkdir -p "$INSTALL_ROOT"

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

  echo "Activating install at: $TARGET_DIR"
  mv "$STAGED_TARGET" "$TARGET_DIR"

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

  if [[ ! -L "$CURRENT_LINK" && ! -d "$CURRENT_LINK" ]]; then
    echo "llama.cpp: not installed (${INSTALL_ROOT})"
    return 0
  fi

  local INSTALLED_TAG=""
  if [[ -L "$CURRENT_LINK" ]]; then
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
    [[ "$current_dir" != /* ]] && current_dir="${INSTALL_ROOT}/${current_dir}"
  fi

  local found=0
  local dir
  for dir in "$INSTALL_ROOT"/llama-*/; do
    [[ -d "$dir" ]] || continue
    found=1
    local tag
    tag="$(basename "$dir")"
    tag="${tag#llama-}"
    local dir_abs="${dir%/}"
    if [[ "$dir_abs" == "$current_dir" ]]; then
      printf '  %s  (current)\n' "$tag"
    else
      printf '  %s\n' "$tag"
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
