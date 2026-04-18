# Corral ✨🦙

Run local models with the ease of [Ollama](https://ollama.com) and full power of official [llama.cpp](https://github.com/ggml-org/llama.cpp) releases and [MLX](https://github.com/ml-explore/mlx-lm) on Apple Silicon.

**Corral is just a shell script**. It installs and updates official latest llama.cpp and MLX releases, uses the standard Hugging Face registry for models, and provides an Ollama-style CLI for running and managing local models: *search*, *pull*, *run*, *serve*, *launch*, *list*, *remove*, *update*, etc. along with templated usage profiles and tool launchers.

```sh
corral search gemma
corral run unsloth/gemma-4-26B-A4B-it-GGUF
corral launch pi
```

## Why Corral?

- Upstream, official llama.cpp and MLX builds, with their latest performance benefits and model support (*ahem*, [Gemma 4](https://deepmind.google/models/gemma/gemma-4/)) vs downstream integrations and forks
- Ollama-style ergonomics for running *and* managing local models, without an always-on daemon
- The full Hugging Face model registry, not just what Ollama ships
- Model search and discovery against Hugging Face from the command line
- Saved, templated, profiles for pinning a model with a specific set of flags
- Pre-configured launcher for tools including [OpenCode](https://opencode.ai) and [Pi](https://pi.dev)
- Command, model, profile, and quant shell completions for fish, zsh, and bash
- Standard HF cache. Downloaded models are visible to other tools

## Does the world really need this?

Not really.

## Install

```sh
# System-wide
sudo curl -fsSL https://github.com/mmonteleone/corral/releases/latest/download/corral \
  -o /usr/local/bin/corral && sudo chmod +x /usr/local/bin/corral

# Or user-local (no sudo)
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
corral search gemma                           # Find models on Hugging Face
corral run unsloth/gemma-4-26B-A4B-it-GGUF    # Chat (downloads on first use)
corral run mlx-community/gemma-4-26b-a4b-it-6bit  # MLX model (auto-detected)
corral serve unsloth/gemma-4-26B-A4B-it-GGUF  # OpenAI-compatible API + web UI

corral run unsloth/gemma-4-26B-A4B-it-GGUF -- -ngl 999 -c 8192  # Extra flags

# Profiles: save a name + model + flags combo
corral profile set coder unsloth/gemma-4-26B-A4B-it-GGUF -- \
  --ctx-size 65536 --temp 0.2 -ngl 999
corral run coder

# Or seed a profile from a built-in template
corral profile set mycoder code unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M
corral run mycoder

# Launch supported coding harnesses against a running server
corral launch pi
corral launch opencode

corral list                                  # Models, profiles, templates
corral remove unsloth/gemma-4-26B-A4B-it-GGUF
corral remove coder
```

## Commands

| Command | Description |
|---|---|
| `install` | Install backend(s) and shell completions |
| `run MODEL\|PROFILE` | Interactive chat (`llama-cli` / `mlx_lm.chat`) |
| `serve MODEL\|PROFILE` | OpenAI-compatible server (`llama-server` / `mlx_lm.server`) |
| `launch TOOL` | Configure and launch `pi` or `opencode` against a running server |
| `pull MODEL` | Download model artifacts without running |
| `search QUERY` | Search Hugging Face for compatible models |
| `browse MODEL` | Open a model's Hugging Face page in the browser |
| `list` / `ls` | List cached models, profiles, and templates |
| `remove` / `rm` | Remove cached models or profiles |
| `profile set\|show\|duplicate` | Manage saved profiles |
| `template show\|set\|remove` | Manage flag templates |
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

MLX models use plain IDs without `:QUANT` (e.g. `mlx-community/gemma-4-26b-a4b-it-6bit`).

All models are stored in the standard Hugging Face cache (`~/.cache/huggingface/hub/`).

### Search

```sh
corral search gemma                                    # trending (default)
corral search qwen --quants                            # show quant variants
corral search llama --sort downloads --limit 10
corral search mistral --json                           # machine-readable
corral search mistral --quiet                          # one ID per line
corral search --backend mlx qwen                       # MLX-only models
```

### List and remove

```sh
corral list                     # all models, profiles, templates
corral ls --models              # only models
corral ls --backend mlx         # only MLX models
corral ls --json                # JSON output
corral remove USER/MODEL:QUANT  # remove one quant (llama.cpp)
corral remove USER/MODEL        # remove entire model
corral remove PROFILE_NAME      # remove a profile
```

## Profiles and templates

A **profile** saves a model + flags under a name, usable anywhere a model is accepted:

```sh
corral profile set coder unsloth/gemma-4-26B-A4B-it-GGUF -- \
  --ctx-size 65536 --temp 0.2 -ngl 999

corral run coder
corral serve coder
corral run coder -- --temp 0.5   # inline flags override profile flags
```

A **template** is a reusable set of flags that can seed profiles. Corral ships two:

| Template | Purpose | Key flags |
|---|---|---|
| `chat` | Conversational | `--temp 0.8` |
| `code` | Coding | `--temp 0.2` |

```sh
corral profile set mycoder code unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M   # from template
corral run mycoder
```

Create custom templates with `corral template set`. If a template includes a `model=` line, the model is optional when creating profiles from it:

```sh
corral template set work-chat user/our-llm:Q4_K -- --temp 0.6 --ctx-size 16384
corral profile set alice-chat work-chat          # model comes from template
corral profile set test-chat work-chat user/new-llm:Q4_K  # override model
```

```sh
corral profile show coder            # inspect
corral profile duplicate coder coder2
corral template show code
corral template remove work-chat     # delete user template
```

### Profile file format

Profiles are plain text in `~/.config/corral/profiles/` with a `model=` line and flags (one per line). Section headers scope flags to a backend, command, or both:

```
model=unsloth/gemma-4-26B-A4B-it-GGUF
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
-ngl 999

[llama.cpp.serve]
--cache-reuse 256

```

| Section | Scope |
|---|---|
| *(none)* | All backends and commands |
| `[run]` / `[serve]` | One command, any backend |
| `[llama.cpp]` / `[mlx]` | One backend, any command |
| `[llama.cpp.run]` / `[llama.cpp.serve]` / `[mlx.run]` / `[mlx.serve]` | One backend + one command |

`profile set` creates flat profiles. Section headers are added by editing the file directly or inherited from templates. Templates use the same format (`model=` optional) and live in `~/.config/corral/templates/`. A user-defined template with the same name as a built-in takes precedence.

## Launch coding harnesses

`corral launch` configures a supported coding harness to use a currently running `corral serve` instance, then launches the harness.

Supported harnesses currently include `pi` and `opencode`. Corral inspects running servers via `corral ps`, matches the server's local OpenAI-compatible endpoint and model name, and writes that into the harness config. Existing configs are preserved with a timestamped backup next to any modified config file

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

## Development

Source entry point is [src/corral.sh](src/corral.sh) with modules in [src/lib/](src/lib/). The standalone distributable is built by [tools/build.sh](tools/build.sh), which inlines modules and stamps the version from the current git tag.

```sh
bash tools/build.sh              # build standalone artifact
shellcheck src/corral.sh src/lib/*.sh   # lint
bash tests/unit.sh               # unit tests
bash tests/smoke.sh              # smoke tests
```

## License

MIT License. Copyright (c) 2026 Michael Monteleone.

Corral is not affiliated with [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggml-org/llama.cpp), [MLX](https://github.com/ml-explore/mlx-lm), or [Hugging Face](https://huggingface.co).
