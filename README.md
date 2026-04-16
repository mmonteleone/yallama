# Fold 🦙

Run local models with the ease of [Ollama](https://ollama.com) and the power of official [llama.cpp](https://github.com/ggml-org/llama.cpp) releases with full [Hugging Face GGUF](https://huggingface.co/models?library=gguf&sort=trending) model access.

Fold is just a shell script. It installs official llama.cpp releases, uses the standard Hugging Face cache, and provides an Ollama-style CLI for running and managing local models: *search*, *pull*, *run*, *serve*, *list*, *remove*, *update*, etc. along with templated usage profile helpers.

## Why use it?

- Upstream, official llama.cpp — all its performance benefits and model support (*ahem*, [Gemma 4](https://deepmind.google/models/gemma/gemma-4/)) vs downstream integrations and forks
- Ollama-style ergonomics for running *and* managing local models, without an always-on daemon
- The full Hugging Face model registry, not just what Ollama ships
- Built-in chat UI and OpenAI-compatible API endpoint via `llama-server`
- Model search and discovery against Hugging Face from the command line
- Saved, templated, profiles for pinning a model with a specific set of flags
- Command, model, profile, and quant shell completions for fish, zsh, and bash
- Standard HF cache — downloaded models are visible to other tools

## Does the world really need this?

Not really.

## Install

Download the script system-wide:

```sh
sudo curl -fsSL https://github.com/mmonteleone/fold/releases/latest/download/fold -o /usr/local/bin/fold && sudo chmod +x /usr/local/bin/fold
```

Or user-local (no `sudo`):

```sh
curl -fsSL https://github.com/mmonteleone/fold/releases/latest/download/fold -o ~/.local/bin/fold && chmod +x ~/.local/bin/fold
```

> [!NOTE]
> `~/.local/bin` may not be in your `$PATH` by default on macOS. If `fold` isn't found after installing, add it: `export PATH="$HOME/.local/bin:$PATH"` in your shell profile.

Then install llama.cpp and set up shell completions:

```sh
fold install
```

`fold install` downloads the latest llama.cpp release and — after prompting — adds it to your `$PATH` and installs shell completions for your current shell. Pass `--shell-profile` to skip the prompt and allow edits automatically, or `--no-shell-profile` to skip profile edits entirely.

## Quick start

```sh
# Find a model
fold search gemma

# Chat with a model (downloads on first use)
fold run unsloth/gemma-4-26B-A4B-it-GGUF

# Serve as an OpenAI-compatible API + web UI at http://localhost:8080
fold serve unsloth/gemma-4-26B-A4B-it-GGUF

# Pass extra llama.cpp flags after '--'
fold run unsloth/gemma-4-26B-A4B-it-GGUF -- -ngl 999 -c 8192

# Save a profile — name + model + flags
fold profile set coder unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL -- \
  --ctx-size 65536 --temp 0.2 -ngl 999

# Use it anywhere you'd use a model name
fold run coder

# Or create one from a built-in template
fold profile set mycoder code unsloth/Qwen3.5-27B-GGUF

# List everything: models, profiles, templates
fold list

# Remove a model or profile
fold remove unsloth/gemma-4-26B-A4B-it-GGUF
fold remove coder
```

## Commands

| Command | What it does |
|---|---|
| `install` | Install llama.cpp, set up `$PATH` and shell completions |
| `run <MODEL[:QUANT]\|PROFILE>` | Download model if needed, start chat via `llama-cli` |
| `serve <MODEL[:QUANT]\|PROFILE>` | Download model if needed, start API server via `llama-server` |
| `pull <MODEL[:QUANT]>` | Download a model (or specific quant) without running it |
| `search <QUERY>` | Search Hugging Face for GGUF models |
| `browse <MODEL>` | Open a model's Hugging Face page in the browser |
| `list` / `ls` | List downloaded models, profiles, and templates |
| `remove` / `rm` | Delete a model, quant variant, or profile |
| `profile set` | Create or replace a profile (from a model or template) |
| `profile show` | Print a profile's contents |
| `profile duplicate` | Copy a profile to a new name |
| `template show` | Print a template's contents |
| `template set` | Create or replace a user-defined template |
| `template remove` | Delete a user-defined template |
| `status` | Show installed version and check for updates |
| `update` | Update llama.cpp to the latest release |
| `versions` | List installed llama.cpp versions |
| `prune` | Remove old versions, keep current |
| `uninstall` | Remove the llama.cpp install |
| `ps` | Show running models |
| `version` | Show the fold version |

Run `fold <command> --help` for per-command flags and usage.

## Shell completions

Completions for commands, model names, quant variants, and profile names are available for fish, zsh, and bash. They are installed automatically when `fold install` edits your shell profile. If you skipped shell profile edits during `fold install`, re-run it with `--shell-profile` to enable them:

```sh
fold install --shell-profile
```

## Model search

```sh
fold search gemma                        # keyword search, sorted by trending
fold search qwen --quants                # show available quant variants
fold search llama --sort downloads --limit 10
fold search mistral --json               # machine-readable
fold search mistral --quiet              # one model ID per line
fold browse unsloth/gemma-4-26B-A4B-it-GGUF        # open in browser
```

## Models and quants

Use the standard Hugging Face `USER/MODEL` format, optionally with `:QUANT`:

```sh
fold run unsloth/gemma-4-26B-A4B-it-GGUF            # default quant
fold run unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K    # specific quant
```

`fold list` shows downloaded models, profiles, and templates in separate sections. Scope the output with `--models`, `--profiles`, or `--templates`:

```sh
fold list                   # all sections
fold ls --quiet             # machine-friendly, one entry per line
fold ls --json              # JSON array with a "kind" field
fold ls --models            # only downloaded models
```

`fold remove USER/MODEL:QUANT` removes a single quant variant; omit `:QUANT` to remove the whole model. `fold remove PROFILE_NAME` removes a profile.

Models are stored in the standard Hugging Face cache (`~/.cache/huggingface/hub/`).

## Profiles and templates

A **profile** is a named model + flags combination you can use anywhere a model name is accepted:

```sh
# Create a profile from a model spec and flags
fold profile set coder unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL -- \
  --ctx-size 65536 --temp 0.2 -ngl 999

# Use it with run or serve
fold run coder
fold serve coder
fold run coder -- --temp 0.5   # extra flags override profile flags
```

A **template** is a reusable set of flags that can seed profiles. Fold ships two built-in templates:

| Template | Use case | Key flags |
|---|---|---|
| `chat` | Conversational | `--temp 0.8 --ctx-size 8192` |
| `code` | Coding | `--temp 0.2 --ctx-size 65536` |

Create a profile from a template:

```sh
fold profile set mycoder code unsloth/Qwen3.5-27B-GGUF
fold run mycoder
```

Create your own templates with `template set`. If a template includes a `model=` line, the model argument is optional when creating profiles from it:

```sh
# Create a team template with a pinned model
fold template set work-chat user/our-llm:Q4_K -- --temp 0.6 --ctx-size 16384

# Create profiles from it — model comes from the template
fold profile set alice-chat work-chat
fold profile set bob-chat work-chat

# Override the model for one profile
fold profile set test-chat work-chat user/new-llm:Q4_K
```

Other profile and template commands:

```sh
fold profile show coder          # print a profile's contents
fold profile duplicate coder coder2
fold template show code          # print a template's contents
fold template remove work-chat   # delete a user-defined template
fold remove coder                # delete a profile
```

### Profile file format

Profiles are plain text files in `~/.config/fold/profiles/`. Each has a `model=` line followed by flags, one per line:

```
model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
--ctx-size 65536
--temp 0.2
-ngl 999
```

Use `[run]` and `[serve]` section headers to scope flags to a specific command. Flags before any header apply to both:

```
model=unsloth/gemma-4-26B-A4B-it-GGUF:UD-Q6_K_XL
--ctx-size 65536
--temp 0.2
-ngl 999

[serve]
--cache-reuse 256
```

Section headers are added by editing the file directly; `profile set` creates flat (no-section) profiles.

Templates use the same format (`model=` is optional) and are stored in `~/.config/fold/templates/`. Built-in templates cannot be removed, but a user-defined template with the same name takes precedence.

## Configuration

Environmental variables:

- `FOLD_INSTALL_ROOT`: overrides the directory where llama.cpp is installed. Used by `run`, `serve`, and `pull` to locate binaries.
- `FOLD_PROFILES_DIR`: overrides the directory where profiles are stored. Defaults to `~/.config/fold/profiles`.
- `FOLD_TEMPLATES_DIR`: overrides the directory where user-defined templates are stored. Defaults to `~/.config/fold/templates`.
- `HF_TOKEN`: is passed through for private or gated Hugging Face models. `HF_HUB_TOKEN` and `HUGGING_FACE_HUB_TOKEN` also work.


## Uninstall

Remove llama.cpp and the fold script itself:

```sh
fold uninstall --self
```

To also wipe all downloaded models from the Hugging Face cache:

```sh
fold uninstall --self --delete-hf-cache
```

Both steps prompt for confirmation. Add `--force` to skip prompts.

## Compatibility

- macOS arm64 / x86_64 and Linux x86_64 / arm64
- Tools: `curl`, `tar`, `jq`, and standard POSIX userland tools
- fish, zsh, and bash for PATH/completion setup
- `install` and `update` are atomic
- `remove` refuses to delete models that are currently in use

## Development

[src/fold.sh](src/fold.sh) is the modular source entrypoint. The domain modules live under [src/lib/](src/lib/). Standalone release artifacts are built from these sources by `tools/build.sh`, which inlines all modules and stamps in the version from the current git tag.

Generate a standalone release artifact locally with:

```sh
bash tools/build.sh
```

## Validation

```sh
shellcheck src/fold.sh src/lib/*.sh
bash tests/unit.sh
bash tests/smoke.sh
```

## License

MIT License

Copyright (c) 2026 Michael Monteleone

Fold is an independent project and is not affiliated with or associated with [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggml-org/llama.cpp), or [Hugging Face](https://huggingface.co).
