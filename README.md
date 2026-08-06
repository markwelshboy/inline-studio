# Inline Studio — RunPod image

A headless CUDA image for running [Inline Studio](https://github.com/inlineresearch/Inline-Studio) on RunPod or a similar GPU host.

The container runs one Python process that serves both the Inline Studio SPA and Inline Core API on port `8848`. It deliberately does **not** include Chrome, X11, noVNC, or a desktop environment. Use the RunPod HTTP proxy or an SSH tunnel from your local browser.

## Included

- Inline Studio / Inline Core pinned to `v1.2.63` by default
- CUDA 12.8 runtime and the existing cu128 Torch pin set
- Local generation and LoRA training dependencies
- Prebuilt browser SPA served by Inline Core
- OpenSSH server for tunnel access
- `pod-runtime` checked out at `/opt/pod-runtime`
- `hff` and HF manifest helpers from `pod-runtime`
- Persistent models, projects, databases, extensions, caches, and logs under `/workspace`
- A single final/headless Docker target

## Build and push

```bash
chmod +x build_inline-studio.sh
./build_inline-studio.sh
```

The default image is:

```text
markwelshboy/inline-studio:latest
```

Useful variations:

```bash
# Build and load locally instead of pushing
./build_inline-studio.sh --load

# Publish a versioned tag
./build_inline-studio.sh --tag v1.2.63 --image-version 1.2.63

# Track another upstream tag or commit
./build_inline-studio.sh --inline-ref main

# Include Inline Core's optional xDiT/xfuser multi-GPU extra
./build_inline-studio.sh --parallel
```

The script pushes by default and uses `docker buildx`. Run `./build_inline-studio.sh --help` for all options.

## RunPod template

Use the image `markwelshboy/inline-studio:latest` and expose:

| Container port | Type | Purpose |
|---|---|---|
| `8848` | HTTP | Inline Studio UI/API and WebSockets |
| `22` | TCP | Optional SSH and local port forwarding |

Keep `/workspace` on the RunPod volume. The default persistent layout is:

```text
/workspace/inline-studio/
  models/
  data/
  extensions/
  studio-data/
  projects/
  logs/
/workspace/huggingface/
```

### Recommended environment variables

```text
ENABLE_SSH=true
SSH_PUBLIC_KEY=ssh-ed25519 AAAA...your-public-key
HF_TOKEN=hf_...
```

Inline Studio binds to `0.0.0.0:8848` by default. Access it through the provider's authenticated HTTP proxy.

### SSH tunnel

When RunPod supplies the external host and mapped TCP port for container port 22:

```bash
ssh -p <mapped-ssh-port> \
  -L 8848:127.0.0.1:8848 \
  root@<pod-host>
```

Then open:

```text
http://127.0.0.1:8848
```

The SSH helper accepts either `SSH_PUBLIC_KEY` or the legacy `PUBLIC_KEY` variable. Password login is disabled.

## Models

Inline Studio scans `INLINE_MODELS_DIR`, which defaults to:

```text
/workspace/inline-studio/models
```

The image creates the common model directories:

```text
models/
  diffusion_models/
  checkpoints/
  text_encoders/
  vae/
  loras/
  controlnet/
  clip_vision/
  upscale_models/
```

You can upload files over SSH, use Inline Studio's explicit model-download UI, use `hff`, or use the optional `pod-runtime` manifest downloader.

### Optional model manifest bootstrap

```text
ENABLE_MODEL_MANIFEST_DOWNLOAD=true
MODEL_MANIFEST_URL=https://raw.githubusercontent.com/.../model_manifest.json
WAIT_FOR_MODEL_DOWNLOADS=true
```

The `pod-runtime` manifest format controls which sections are enabled through section environment variables such as `download_<section>=true`. Downloads default to completing before Inline Studio starts, because Inline Core scans the model tree at startup.

Set this only when a failed manifest must prevent the application from starting:

```text
REQUIRE_MODEL_MANIFEST_SUCCESS=true
```

## Inline Studio runtime settings

Common upstream settings can be passed directly:

```text
INLINE_PROFILE=lowvram
INLINE_VRAM_BUDGET_GB=16
INLINE_PARALLEL=pipefusion=2
INLINE_LOG_LEVEL=INFO
```

The persistent paths can also be overridden:

```text
INLINE_MODELS_DIR=/workspace/inline-studio/models
INLINE_DATA_DIR=/workspace/inline-studio/data
INLINE_EXTENSIONS_DIR=/workspace/inline-studio/extensions
INLINE_STUDIO_DATA_DIR=/workspace/inline-studio/studio-data
INLINE_STUDIO_WORKSPACE_DIR=/workspace/inline-studio/projects
```

## Shell helpers

After connecting over SSH:

```bash
inline-health     # formatted /v1/health response
inline-log        # follow startup/application logs
inline-models     # summarize model disk use
hff --help        # pod-runtime Hugging Face file tool
pod_runtime_load  # source the broader pod-runtime helper library
```

The startup environment is preserved in `/root/.secrets/env.current` so SSH shells inherit the provider-supplied variables.

## Security

Inline Studio is intended to be used as a trusted service. Do not publish port `8848` anonymously to the public internet. Prefer the RunPod authenticated proxy, an SSH tunnel, Tailscale, or a reverse proxy with authentication.

## Source and licensing

The image builds the unmodified upstream Inline Studio source at the selected ref and records the resolved commit in `/opt/inline-studio/INLINE_STUDIO_COMMIT`. Inline Studio is licensed under GPL-3.0-or-later. `pod-runtime` is fetched from the configured repository/ref and its resolved commit is recorded alongside it.
