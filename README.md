# Yallama

Run local models with the ease of [Ollama](https://ollama.com) and the power of official [llama.cpp](https://github.com/ggml-org/llama.cpp) releases with full [Hugging Face GGUF](https://huggingface.co/models?library=gguf&sort=trending) model access.

Tagged Yallama releases ship a single Bash script artifact that installs official llama.cpp releases, uses the standard Hugging Face cache, and wraps a thin CLI to simulate common Ollama-style flows for interacting with models: *pull*, *run*, *serve*, *list*, *remove*, *update*, etc. The repository itself keeps modular Bash sources.

## Why use it?

- Upstream, official, llama.cpp with all its perf benefits and model support (*ahem*, [Gemma 4](https://deepmind.google/models/gemma/gemma-4/)) vs downstream integrations and forks
- Same ergonomics as Ollama for lazy people like me, including ease of running *and* managing local models
- Broad Hugging Face model registry, not easily reached through Ollama
- Built-in chat UI and OpenAI API endpoint compatibility thanks to `llama-server`
- Command, model, and quant shell completions for fish, zsh, and bash
- Templated profiles for common model usage
- No always-on daemon
- Standard HF cache, so downloaded models are visible to other tools

## Does the world really need this?

Not really.

## Install

System-wide:

```sh
sudo curl -fsSL https://github.com/mmonteleone/yallama/releases/latest/download/yallama -o /usr/local/bin/yallama && sudo chmod +x /usr/local/bin/yallama
```

User-local (no `sudo`):

```sh
curl -fsSL https://github.com/mmonteleone/yallama/releases/latest/download/yallama -o ~/.local/bin/yallama && chmod +x ~/.local/bin/yallama
```

Then install llama.cpp:

```sh
yallama install
```

## Quick start

```sh
# Chat with a model
yallama run unsloth/gemma-4-26B-A4B-it-GGUF

# Serve the same model as an OpenAI-compatible API + web UI at http://localhost:8080
yallama serve unsloth/gemma-4-26B-A4B-it-GGUF

# List downloaded models (and their variants)
yallama list

# Remove a model
yallama remove unsloth/gemma-4-26B-A4B-it-GGUF
```

Or specify quants

```sh
# Chat with a specific quant variant
yallama run unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K

# Remove only a specific quant variant
yallama rm unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K
```

Pass extra llama.cpp flags after `--`:

```sh
yallama run unsloth/gemma-4-26B-A4B-it-GGUF -- -ngl 999 -c 8192
yallama serve unsloth/gemma-4-26B-A4B-it-GGUF -- --port 8081
```

Or use a saved profile:

```sh
# Save a profile
yallama profile set coder unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL -- \
  --ctx-size 65536 --temp 0.2 --top-k 20 -ngl 999

# Use it — model and flags are loaded automatically
yallama serve coder
yallama run coder -- --temp 0.5   # extra flags appended, overriding profile
```

## Commands

| Command | What it does |
|---|---|
| `install` | Install llama.cpp |
| `run <MODEL[:QUANT]\|PROFILE>` | Download model if needed, start chat via `llama-cli` |
| `serve <MODEL[:QUANT]\|PROFILE>` | Download model if needed, start chat and API server via `llama-server` |
| `pull <MODEL[:QUANT]>` | Download a model (or specific quant) without running it |
| `list` / `ls` | List downloaded models, including per-quant rows for GGUF variants |
| `remove <MODEL[:QUANT]>` / `rm <MODEL[:QUANT]>` | Delete an entire model or just one quant variant |
| `profile` | Manage named run/serve profiles |
| `status` | Show installed version and optionally check for updates |
| `update` | Update llama.cpp to the latest release |
| `versions` | List installed llama.cpp versions |
| `prune` | Remove old versions, keep current |
| `uninstall` | Remove the llama.cpp install |
| `ps` | Show running models |
| `version` | Show the yallama version |

For flags and per-command help:

```sh
yallama help
yallama install --help
yallama run --help
```

## Model names

Use the normal Hugging Face `USER/MODEL` format, with optional `:QUANT`, for example:

- `unsloth/gemma-4-26B-A4B-it-GGUF`
- `unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K`
- `unsloth/Qwen3.5-35B-A3B-GGUF`

When you include `:QUANT`, yallama passes that through to llama.cpp model selection and treats it as a separate variant for `run`, `serve`, `list` and `remove`.

```sh
yallama list
yallama ls --quiet
yallama ls --json
```

`yallama remove USER/MODEL:QUANT` removes only that quant variant. Omitting `:QUANT` removes the whole model.

Models are stored in the standard Hugging Face cache under `~/.cache/huggingface/hub/`.

## Profiles

Profiles let you give a name to a model + flags combination and use it in place of a model spec:

```sh
yallama profile set coder unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL -- \
  --ctx-size 65536 \
  --n-predict 4096 \
  --temp 0.2 \
  --top-k 20 \
  --repeat-penalty 1.05 \
  --flash-attn on \
  -ngl 999

yallama serve coder
```

Profile subcommands:

| Subcommand | What it does |
|---|---|
| `profile set <NAME> <MODEL> [-- <flags>]` | Create or replace a profile |
| `profile list` | List all saved profiles |
| `profile show <NAME>` | Print a profile's contents |
| `profile remove <NAME>` | Delete a profile |
| `profile duplicate <SOURCE> <DEST>` | Copy a profile to a new name |
| `profile new <NAME> <TEMPLATE> [<MODEL>]` | Create a profile from a template |
| `profile templates` | List all available templates |
| `profile template-show <TEMPLATE>` | Print a template's contents |
| `profile template-set <TEMPLATE> [<MODEL>] [-- <flags>]` | Create or replace a user-defined template |
| `profile template-remove <TEMPLATE>` | Delete a user-defined template |

Profiles are stored as plain text files in `~/.config/yallama/profiles/`. Each file has a `model=` line followed by one flag-and-value pair per line:

```
model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
--temp 0.2
--flash-attn on
-ngl 999
```

Some flags are only valid for one command — for example, `--cache-reuse` is only supported by `llama-server` (`serve`), not `llama-cli` (`run`). Use `[serve]` and `[run]` section headers to scope flags to the appropriate command. Flags before any section header are passed to both:

```
model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
# common flags (passed to both run and serve)
--ctx-size 65536
--n-predict 4096
--temp 0.2
--top-k 20
--repeat-penalty 1.05
--flash-attn on
-ngl 999

[serve]
# only passed to llama-server
--cache-reuse 256
```

Section headers are added by editing the profile file directly. `profile set` creates a flat (no-section) profile.

### Templates

Templates are reusable flag presets that you can use to quickly create profiles. Yallama includes a couple built-in templates:

| Template | Best for | Key flags |
|---|---|---|
| `chat` | Conversational use | `--temp 0.8 --ctx-size 8192` |
| `code` | Coding assistants | `--temp 0.2 --ctx-size 65536` |

Create a profile from a built-in template by supplying the model:

```sh
yallama profile new mycoder code unsloth/Qwen3.5-27B-GGUF:UD-Q5_K_XL
yallama run mycoder
```

If a template includes a `model=` line (user-defined templates can embed one), the model argument is optional:

```sh
# Create a team template with a pinned model and shared flags
yallama profile template-set work-chat user/our-llm:Q4_K -- --temp 0.6 --ctx-size 16384

# Create profiles from it — model comes from the template
yallama profile new alice-chat work-chat
yallama profile new bob-chat work-chat

# Override the model for a specific profile
yallama profile new test-chat work-chat user/new-llm:Q4_K
```

Templates are stored as plain text files in `~/.config/yallama/templates/` and have the same format as profiles (`model=` is optional). Built-in templates are always available and cannot be removed, but a user-defined template with the same name takes precedence.

## Configuration

Environmental variables:

- `YALLAMA_INSTALL_ROOT`: overrides the directory where llama.cpp is installed. Used by `run`, `serve`, and `pull` to locate binaries.
- `YALLAMA_PROFILES_DIR`: overrides the directory where profiles are stored. Defaults to `~/.config/yallama/profiles`.
- `YALLAMA_TEMPLATES_DIR`: overrides the directory where user-defined templates are stored. Defaults to `~/.config/yallama/templates`.
- `HF_TOKEN`: is passed through for private or gated Hugging Face models. `HF_HUB_TOKEN` and `HUGGING_FACE_HUB_TOKEN` also work.


## Uninstall

Remove llama.cpp and the yallama script itself:

```sh
yallama uninstall --self
```

To also wipe all downloaded models from the Hugging Face cache:

```sh
yallama uninstall --self --delete-hf-cache
```

Both steps prompt for confirmation. Add `--force` to skip prompts.

## Compatibility

- macOS arm64 / x86_64 and Linux x86_64 / arm64
- fish, zsh, and bash for PATH/completion setup
- `curl`, `tar`, `jq`, and standard POSIX userland tools for install/update

`install` and `update` are atomic. `remove` refuses to delete models that are currently in use.

## Development

The tracked root [yallama](/Users/mmonteleone/source/repos/yallama/yallama) is the modular source entrypoint. Standalone release artifacts are built from it plus the domain modules under [lib](/Users/mmonteleone/source/repos/yallama/lib).

Generate a standalone release artifact locally with:

```sh
bash tools/build-standalone.sh
```

## Validation

```sh
shellcheck yallama
bash tests/smoke.sh
```

## License

MIT License

Copyright (c) 2026 Michael Monteleone

Yallama is an independent project and is not affiliated with or associated with [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggml-org/llama.cpp), or [Hugging Face](https://huggingface.co).
