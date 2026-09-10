# Corral ✨🦙

Run local models with the ease of [Ollama](https://ollama.com) and full power of official [llama.cpp](https://github.com/ggml-org/llama.cpp) releases and [MLX](https://github.com/ml-explore/mlx-lm) on Apple Silicon.

**Corral is just a shell script**. It installs and updates official latest llama.cpp and MLX releases, uses the standard Hugging Face registry for models, and provides an Ollama-style CLI for running and managing local models: *search*, *pull*, *run*, *serve*, *launch*, *list*, *remove*, *update*, etc. along with templated usage profiles and tool launchers.

```sh
corral search gemma
corral run unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL
corral launch pi
```
![screenshot of corral's search command](./images/corral-search.png)
![screenshot of corral's list command](./images/corral-list.png)
## Why Corral?

- Upstream, official llama.cpp and MLX builds, with their latest performance benefits and model support (*ahem*, [Gemma 4](https://deepmind.google/models/gemma/gemma-4/)) vs downstream integrations and forks
- Ollama-style ergonomics for running *and* managing local models, without an always-on daemon
- The full Hugging Face model registry, not just what Ollama ships
- Model search and discovery against Hugging Face from the command line
- Saved, templated, profiles for pinning a model with a specific set of flags
- Pre-configured launcher for tools including [OpenCode](https://opencode.ai), [Pi](https://pi.dev), [Codex](https://openai.com/codex/), [GitHub Copilot CLI](https://github.com/features/copilot/cli), and [GitHub Copilot in Visual Studio Code](https://code.visualstudio.com/).
- Command, model, profile, and quant shell completions for fish, zsh, and bash
- Standard HF cache. Downloaded models are visible to other tools

## Does the world really need this?

Not really.

## Install (or Upgrade)

```sh
curl -fsSL https://github.com/mmonteleone/corral/releases/latest/download/corral \
  -o ~/.local/bin/corral && chmod +x ~/.local/bin/corral
```

> [!NOTE]
> `~/.local/bin` may not be in `$PATH` by default on macOS. Add it: `export PATH="$HOME/.local/bin:$PATH"`

Then install a backend and set up shell completions:

```sh
corral install
```

On Apple Silicon this installs **both** llama.cpp (`llama-cli`, `llama-server`) and MLX (`mlx-lm`). On other platforms, llama.cpp only. Restrict with `--backend llama.cpp` or `--backend mlx`.

`corral install` downloads the latest official llama.cpp release and, after prompting, adds it to `$PATH` and installs shell completions. Pass `--shell-profile` to accept automatically, or `--no-shell-profile` to skip. For MLX, corral installs `mlx-lm` via `uv` (offering to install `uv` via Homebrew if needed).

## Quick start

```sh
corral search gemma                                       # Find models on Hugging Face
corral run unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL # Chat (downloads on first use)
corral run mlx-community/gemma-4-26b-a4b-it-4bit  # MLX model (auto-detected)
corral serve unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL  # OpenAI-compatible API + web UI

corral run unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL -- --gpu-layers all -c 8192  # Extra flags

# Profiles: save a name + model + flags combo
corral profile coder unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL -- \
  --ctx-size 65536 --temp 0.5 --gpu-layers all
corral serve coder

# Or seed a profile from a built-in template
corral profile gemma-coder gemma
corral serve gemma-coder

# Launch supported coding harnesses against a running server
corral launch pi
corral launch opencode
corral launch codex
corral launch copilot
corral launch code

# List models, installed engines, profiles, templates
corral list

corral remove unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL
corral remove coder
```

## Commands

| Command | Description |
|---|---|
| `install` | Install backend(s) and shell completions |
| `run MODEL\|PROFILE` | Interactive chat (`llama-cli` / `mlx_lm.chat`) |
| `serve MODEL\|PROFILE` | OpenAI-compatible server (`llama-server` / `mlx_lm.server`) |
| `launch TOOL` | Configure and launch `pi`, `opencode`, `copilot`, `codex`, or `code` against a running server |
| `pull MODEL` | Download model artifacts without running |
| `search [QUERY]` | Search Hugging Face for compatible models |
| `browse MODEL` | Open a model's Hugging Face page in the browser |
| `list` / `ls` | List cached models, installed engines, profiles, and templates |
| `remove` / `rm` | Remove cached models, profiles, or user templates |
| `profile NAME ...` | Create or replace a saved profile |
| `template NAME ...` | Create or replace a user-defined template |
| `copy` / `cp` | Copy a profile or template |
| `show <NAME>` | Show details about a profile, template, or model |
| `status` | Platform info and installed backend status |
| `update` | Update backends to latest versions |
| `versions` | Show installed backend versions |
| `prune` | Remove old llama.cpp installs (keeps current) |
| `uninstall` | Remove backends and optionally clean up caches |
| `ps` | Show running model processes |
| `version` | Show the corral version |

Run `corral <command> --help` for per-command flags.

## Models and quants

Models use standard Hugging Face `USER/MODEL` IDs. For llama.cpp, append `:QUANT` to pin a quantization:

```sh
corral run unsloth/gemma-4-26B-A4B-it-GGUF            # default quant
corral run unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K    # specific quant
```

MLX models use plain IDs without `:QUANT` (e.g. `mlx-community/gemma-4-26b-a4b-it-4bit`).

All models are stored in the standard Hugging Face cache (`~/.cache/huggingface/hub/`).

### Search

`corral search` defaults to `llama.cpp`/GGUF results. Pass `--backend mlx` when you want MLX-tagged models instead.

```sh
corral search --backend llama.cpp gemma            # GGUF-tagged results
corral search --backend mlx gemma                  # MLX-tagged results
corral search --backend llama.cpp qwen --quants    # show GGUF quant variants
```

### List and remove

```sh
corral list                     # all models, installed engines, profiles, templates
corral ls --models              # only models
corral ls --engines             # only installed engines
corral ls --backend mlx         # only MLX models
corral remove USER/MODEL:QUANT  # remove one quant (llama.cpp)
corral remove USER/MODEL        # remove entire model
corral remove PROFILE_NAME      # remove a profile
corral remove work-chat         # remove a user template
```

## Profiles and templates

A **profile** saves a model + flags under a name, usable anywhere a model is accepted:

```sh
corral profile coder unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL -- \
  --ctx-size 65536 --temp 0.5 --gpu-layers all

corral run coder
corral serve coder
corral run coder -- --temp 0.5   # inline flags override profile flags
```

A **template** is a reusable set of flags that can seed profiles. Corral currently includes a few built-in:

- gemma
- glimmer
- qwen

```sh
# Create a profile from the built-in qwen template
corral profile qwen-coder qwen
corral serve qwen-coder

# Override to a specific model/quant
corral profile qwen-coder qwen unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M
corral serve qwen-coder

# Create a profile from the built-in glimmer template
corral profile glimmer-chat glimmer
corral serve glimmer-chat
```

Create custom templates with `corral template`. If a template includes a `model=` line, the model is optional when creating profiles from it:

```sh
corral template work-chat user/our-llm:Q4_K -- --temp 0.6 --ctx-size 16384
corral profile alice-chat work-chat          # model comes from template
corral profile test-chat work-chat user/new-llm:Q4_K  # override model
```

```sh
corral show coder                            # Show profile details
corral show --template chat                  # Show template details
corral show unsloth/gemma-4-26B-A4B-it-qat-GGUF  # Show model details
corral copy coder coder2
corral cp coder coder3                       # alias
corral copy chat chat-copy                   # copy built-in template
corral cp work-chat work-chat-2              # alias
corral remove work-chat                      # delete user template
```

### Profile file format

Profiles are plain text in `~/.config/corral/profiles/` with a `model=` line and flags (one per line). Section headers scope flags to a backend, command, or both:

```
model=unsloth/gemma-4-26B-A4B-it-qat-GGUF:UD-Q4_K_XL
--temp 0.2

[mlx]
--max-tokens 4096

[mlx.serve]
--top-k 20

[llama.cpp]
--top-k 20
--repeat-penalty 1.05
--ctx-size 65536
--n-predict 4096
--flash-attn on
--gpu-layers all

[llama.cpp.serve]
--cache-reuse 256

```

| Section | Scope |
|---|---|
| *(none)* | All backends and commands |
| `[run]` / `[serve]` | One command, any backend |
| `[llama.cpp]` / `[mlx]` | One backend, any command |
| `[llama.cpp.run]` / `[llama.cpp.serve]` / `[mlx.run]` / `[mlx.serve]` | One backend + one command |

`profile` creates flat profiles. Section headers are added by editing the file directly or inherited from templates. Templates use the same format (`model=` optional) and live in `~/.config/corral/templates/`. A user-defined template with the same name as a built-in takes precedence.

### Multi-Token Prediction (MTP)

For certain models that support Multi-Token Prediction (MTP) drafting sidecars, Corral manages the required sidecar files automatically.

- When you `pull` or `run` a model requiring an MTP sidecar, Corral downloads it automatically.
- MTP sidecars are excluded from `corral list` to keep your view focused on primary models.

_Ensure you uncomment the profile's use of MTP:_

```
## Uncomment for MTP drafting
# --spec-type draft-mtp
# --spec-draft-n-max 3
```

## Launch coding harnesses

`corral launch` configures a supported coding harness to use a currently running `corral serve` instance, then launches the harness.

Supported harnesses currently include `pi`, `opencode`, `codex`, `copilot`, and `code`. Corral inspects running servers via `corral ps`, matches the server's local OpenAI-compatible endpoint, model, context window, and max tokens, and configures the harness for that invocation. Existing file-backed configs are preserved with a timestamped backup next to any modified config file. `copilot launch` exports `COPILOT_PROVIDER_BASE_URL`, `COPILOT_MODEL`, `COPILOT_PROVIDER_MAX_PROMPT_TOKENS`, and `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS` based on the running server's discovered context window. `code` updates VS Code's `chatLanguageModels.json` with a Corral custom endpoint using the same token limits. `codex`, `copilot`, and `code` currently require the `llama.cpp` backend.

## Shell completions

Completions for commands, models, quants, and profiles are available for **fish**, **zsh**, and **bash**. They install automatically during `corral install` when shell profile edits are accepted. To add them later:

```sh
corral install --shell-profile
```

## Configuration

| Variable | Purpose |
|---|---|
| `CORRAL_INSTALL_ROOT` | Override llama.cpp install directory |
| `CORRAL_PROFILES_DIR` | Override profiles directory (default: `~/.config/corral/profiles`) |
| `CORRAL_TEMPLATES_DIR` | Override templates directory (default: `~/.config/corral/templates`) |
| `HF_TOKEN` | Authenticate for private/gated HF models (`HF_HUB_TOKEN` and `HUGGING_FACE_HUB_TOKEN` also work) |

## Uninstall

```sh
corral uninstall --self                      # remove all backends + corral itself
corral uninstall --backend mlx               # remove one backend
corral uninstall --self --delete-hf-cache    # also wipe downloaded models
```

All uninstall commands prompt for confirmation. Add `--force` to skip.

## Compatibility

| | Platforms |
|---|---|
| **llama.cpp** | macOS arm64/x86_64, Linux x86_64/arm64 |
| **MLX** | macOS arm64 only (Apple Silicon) |

Requires `curl`, `tar`, `jq`, and standard POSIX tools. MLX operations require `uv`. Shell completions support fish, zsh, and bash. `install` and `update` are atomic. `remove` refuses to delete models currently in use.

## License

MIT License. Copyright (c) 2026 Michael Monteleone.

Corral is not affiliated with [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggml-org/llama.cpp), [MLX](https://github.com/ml-explore/mlx-lm), or [Hugging Face](https://huggingface.co).
