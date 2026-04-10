# Yallama

Run local models with the ease of [Ollama](https://ollama.com) and the power of official [llama.cpp](https://github.com/ggml-org/llama.cpp) releases with full [Hugging Face GGUF](https://huggingface.co/models?library=gguf&sort=trending) model access.

Yallama is a single Bash script that installs official llama.cpp releases, uses the standard Hugging Face cache, and wraps a thin CLI to simulate common Ollama-style flows for interacting with models: *pull*, *run*, *serve*, *list*, *remove*, *update*, etc.

## Why use it?

- Upstream, official, llama.cpp with all its perf benefits and model support (*ahem*, [Gemma 4](https://deepmind.google/models/gemma/gemma-4/)) vs downstream integrations and forks
- Same ergonomics as Ollama for lazy people like me, including ease of running *and* managing local models
- Broad Hugging Face model registry, not easily reached through Ollama
- Built-in chat UI and OpenAI API endpoint compatibility thanks to `llama-server`
- Command and model shell completions for fish, zsh, and bash
- No always-on daemon
- Standard HF cache, so downloaded models are visible to other tools

## Does the world really need this?

Not really.

## Install

System-wide:

```sh
sudo curl -fsSL https://raw.githubusercontent.com/mmonteleone/yallama/refs/heads/main/yallama -o /usr/local/bin/yallama && sudo chmod +x /usr/local/bin/yallama
```

User-local (no `sudo`):

```sh
curl -fsSL https://raw.githubusercontent.com/mmonteleone/yallama/refs/heads/main/yallama -o ~/.local/bin/yallama && chmod +x ~/.local/bin/yallama
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

# List cached models
yallama list

# Remove a model
yallama remove unsloth/gemma-4-26B-A4B-it-GGUF
```

Pass extra llama.cpp flags after `--`:

```sh
yallama run unsloth/gemma-4-26B-A4B-it-GGUF -- -ngl 999 -c 8192
yallama serve unsloth/gemma-4-26B-A4B-it-GGUF -- --port 8081
```

## Commands

| Command | What it does |
|---|---|
| `install` | Install llama.cpp |
| `run <MODEL>` | Download model if needed, start chat via `llama-cli` |
| `serve <MODEL>` | Download model if needed, start chat and API server via `llama-server` |
| `pull <MODEL>` | Download a model without running it |
| `list` / `ls` | List downloaded models |
| `remove <MODEL>` / `rm <MODEL>` | Delete a model |
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

Use the normal Hugging Face `USER/MODEL` format, for example:

- `unsloth/gemma-4-26B-A4B-it-GGUF`
- `unsloth/Qwen3.5-35B-A3B-GGUF`

Models are stored in the standard Hugging Face cache under `~/.cache/huggingface/hub/`.

## Configuration

`YALLAMA_INSTALL_ROOT` overrides the directory where llama.cpp is installed. Used by `run`, `serve`, and `pull` to locate binaries.

```sh
export YALLAMA_INSTALL_ROOT=/opt/llama.cpp
```

`HF_TOKEN` is passed through for private or gated Hugging Face models. `HF_HUB_TOKEN` and `HUGGING_FACE_HUB_TOKEN` also work.

```sh
export HF_TOKEN=hf_your_token_here
```

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

## Validation

```sh
shellcheck yallama
bash tests/smoke.sh
```

## License

MIT License

Copyright (c) 2026 Michael Monteleone

Yallama is an independent project and is not affiliated with or associated with [Ollama](https://ollama.com), [llama.cpp](https://github.com/ggml-org/llama.cpp), or [Hugging Face](https://huggingface.co).
