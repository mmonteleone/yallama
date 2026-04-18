#!/usr/bin/env bash

# corral: Ollama-shaped llama.cpp and model management helper
# https://github.com/mmonteleone/corral

# MIT License

# Copyright (c) 2026 Michael Monteleone

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# set -e: exit immediately on any non-zero return (unless caught by && / || / if).
# set -u: treat references to unset variables as errors.
# set -o pipefail: a pipeline fails if *any* command in it fails (not just the last).
# Together these provide strict error handling that catches common bash pitfalls.
set -euo pipefail

# Resolve the real directory of this script even when invoked via a symlink.
# Using ${BASH_SOURCE[0]} rather than $0 ensures we get the script's own path
# rather than the name of the symlink used to call it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_NAME="${SCRIPT_NAME%.sh}"
# These globals are read by the sourced lib modules; shellcheck can't see
# cross-source usage, so suppress the false "unused" warnings here.
# shellcheck disable=SC2034
DEFAULT_INSTALL_ROOT="${HOME}/.llama.cpp"
# shellcheck disable=SC2034
DEFAULT_PROFILES_DIR="${HOME}/.config/corral/profiles"
# shellcheck disable=SC2034
DEFAULT_TEMPLATES_DIR="${HOME}/.config/corral/templates"
# shellcheck disable=SC2034
HF_HUB_DIR="${HOME}/.cache/huggingface/hub"
# In-process cache for the shell profile edit permission decision.
# Set to "allow" or "deny" by shell_profile_edits_allowed() to avoid
# prompting the user more than once within a single invocation.
# shellcheck disable=SC2034
SHELL_PROFILE_EDIT_DECISION=""
# @VERSION@ is replaced with the git tag by tools/build.sh at build time.
# When running directly from source (dev mode), this placeholder is preserved.
CORRAL_VERSION="@VERSION@"

# Source all library modules. When building a standalone script,
# tools/build.sh replaces the region between the BEGIN/END markers
# with the inlined content of each file.
# BEGIN_GENERATED_MODULES
# shellcheck source=src/lib/corral-helpers.sh
source "${SCRIPT_DIR}/lib/corral-helpers.sh"
# shellcheck source=src/lib/corral-cache.sh
source "${SCRIPT_DIR}/lib/corral-cache.sh"
# shellcheck source=src/lib/corral-profiles.sh
source "${SCRIPT_DIR}/lib/corral-profiles.sh"
# shellcheck source=src/lib/corral-runtime.sh
source "${SCRIPT_DIR}/lib/corral-runtime.sh"
# shellcheck source=src/lib/corral-launch.sh
source "${SCRIPT_DIR}/lib/corral-launch.sh"
# shellcheck source=src/lib/corral-search.sh
source "${SCRIPT_DIR}/lib/corral-search.sh"
# shellcheck source=src/lib/corral-completions.sh
source "${SCRIPT_DIR}/lib/corral-completions.sh"
# END_GENERATED_MODULES

# ── help ──────────────────────────────────────────────────────────────────────

cmd_help() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [options]

Commands:
  install              Install inference backend (mlx or llama.cpp; default: platform-detected)
  update               Update backend components (llama.cpp release or mlx-lm package)
  versions             Show installed backend versions
  prune                Prune old llama.cpp installs (keeps current version)
  uninstall            Uninstall backend components and optional caches
  status               Show installed backend, platform, and version info
  search <QUERY>       Search backend-compatible models (GGUF for llama.cpp, MLX-friendly for mlx)
  browse <MODEL_NAME>  Open a model's HuggingFace page in your browser
  pull <MODEL_NAME>    Download (prefetch) model artifacts without running
  list (ls)            List backend-scoped model cache entries plus profiles and templates
  remove (rm)          Remove backend-scoped model cache entries or a saved profile
  run <MODEL_NAME>     Download and run a HuggingFace model (mlx or llama.cpp)
  serve <MODEL_NAME>   Download and serve a HuggingFace model (mlx or llama.cpp)
  launch <TOOL>        Configure and launch a supported coding harness
  ps                   Show running llama-cli / llama-server / mlx_lm.server processes
  profile              Manage named run/serve profiles
  template             Manage templates
  version (--version)  Show corral version
  help (h, ?)          Show this help

Environment:
  CORRAL_INSTALL_ROOT   Override the default installation root (~/.llama.cpp).
                         Applies to: run, serve, pull.
  CORRAL_PROFILES_DIR   Override the default profiles directory (~/.config/corral/profiles).
  CORRAL_TEMPLATES_DIR  Override the default user templates directory (~/.config/corral/templates).
  HF_TOKEN               HuggingFace access token for private or gated models.
                         Also checked: HF_HUB_TOKEN, HUGGING_FACE_HUB_TOKEN.

Run '$SCRIPT_NAME <command> --help' for command-specific help.
EOF
}

# ── dispatch ──────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"
# 'shift || true': consume the command word without failing when $# is 0,
# since set -euo pipefail would otherwise treat the empty shift as an error.
shift || true

case "$COMMAND" in
  help|h|\?)   cmd_help ;;
  version|--version|-v) printf '%s %s\n' "$SCRIPT_NAME" "$CORRAL_VERSION" ;;
  install)     cmd_install "$@" ;;
  update)      cmd_update "$@" ;;
  uninstall)   cmd_uninstall "$@" ;;
  status)      cmd_status "$@" ;;
  search)      cmd_search "$@" ;;
  browse)      cmd_browse "$@" ;;
  pull)        cmd_pull "$@" ;;
  list|ls)     cmd_list "$@" ;;
  remove|rm)   cmd_remove "$@" ;;
  run)         cmd_run "$@" ;;
  serve)       cmd_serve "$@" ;;
  launch)      cmd_launch "$@" ;;
  ps)          cmd_ps "$@" ;;
  profile)     cmd_profile "$@" ;;
  template)    cmd_template "$@" ;;
  versions)    cmd_versions "$@" ;;
  prune)       cmd_prune "$@" ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    cmd_help >&2
    exit 1
    ;;
esac
