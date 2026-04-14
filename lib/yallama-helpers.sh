# Shared utility helpers for yallama.

# Print an error message to stderr and exit non-zero.
die() { echo "Error: $*" >&2; exit 1; }

# Prompt for a y/N confirmation on stderr. Returns 0 on yes, 1 on no or EOF.
confirm_action() {
  local prompt="$1"
  local reply

  printf '%s [y/N] ' "$prompt" >&2
  # read -r: -r prevents backslash interpretation in the reply.
  # If read hits EOF (e.g. piped input ends), it returns non-zero → return 1.
  read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Determine whether shell profile edits are permitted.
# mode: "always" — permit unconditionally
#       "never"  — deny unconditionally
#       "ask"    — prompt once; the answer is cached in SHELL_PROFILE_EDIT_DECISION
#                  for the duration of this process to avoid repeated prompts.
shell_profile_edits_allowed() {
  local mode="$1"

  case "$mode" in
    always) return 0 ;;
    never) return 1 ;;
    ask)
      # Return early if we already have a cached decision from earlier in this run.
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "allow" ]]; then
        return 0
      fi
      if [[ "$SHELL_PROFILE_EDIT_DECISION" == "deny" ]]; then
        return 1
      fi
      # [[ ! -t 0 ]]: stdin is not a terminal — we're in a non-interactive context
      # (e.g. piped or scripted invocation). Default to deny instead of hanging.
      if [[ ! -t 0 ]]; then
        SHELL_PROFILE_EDIT_DECISION="deny"
        return 1
      fi
      if confirm_action "Allow yallama to edit your shell profile for PATH/completion loading?"; then
        SHELL_PROFILE_EDIT_DECISION="allow"
        return 0
      fi
      SHELL_PROFILE_EDIT_DECISION="deny"
      return 1
      ;;
    *)
      die "invalid shell profile edit mode: ${mode}"
      ;;
  esac
}

# Confirm a destructive operation before proceeding.
# With force=true the prompt is skipped. In non-interactive mode (stdin not a
# terminal) the operation is refused outright unless --force was passed.
confirm_destructive_action() {
  local description="$1"
  local force="$2"

  if [[ "$force" == "true" ]]; then
    return 0
  fi

  # Non-interactive context: refuse rather than silently proceeding.
  if [[ ! -t 0 ]]; then
    die "refusing to ${description} without --force in non-interactive mode."
  fi

  if confirm_action "Proceed with ${description}?"; then
    return 0
  fi

  echo "Aborted." >&2
  return 1
}

# Verify that every listed command exists on PATH, exiting with a helpful
# message if any is missing. llama-cli/llama-server get a hint to run install.
# 'command -v' is the POSIX-portable way to check if a command exists;
# unlike 'which', it also finds builtins and functions and doesn't print output.
require_cmds() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      case "$cmd" in
        llama-cli|llama-server)
          die "required command not found: $cmd (not installed? run: $SCRIPT_NAME install)" ;;
        *)
          die "required command not found: $cmd" ;;
      esac
    }
  done
}

# Prepend the llama.cpp current/ bin dir to PATH if it is not already present.
# ${x/#\~/$HOME}: replace a leading '~' with $HOME inside a variable value;
# the shell's built-in tilde expansion does not apply to variable assignments
# or values that come from other variables.
ensure_llama_in_path() {
  local install_root="${YALLAMA_INSTALL_ROOT:-$DEFAULT_INSTALL_ROOT}"
  # ${x/#\~/$HOME}: bash string substitution anchored to the start (#).
  # Replaces a literal '~' at position 0 with the real HOME path; necessary
  # because tilde expansion only happens at parse time, not in variable values.
  install_root="${install_root/#\~/$HOME}"
  local current_link="${install_root}/current"
  # ":$PATH:" sandwich: wrapping PATH in colons lets the glob *":dir:"*
  # match the dir at the beginning, middle, or end without special-casing.
  if [[ -d "$current_link" ]] && [[ ":$PATH:" != *":${current_link}:"* ]]; then
    export PATH="${current_link}:${PATH}"
  fi
}
