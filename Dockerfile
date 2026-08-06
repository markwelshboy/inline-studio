# syntax=docker/dockerfile:1.7

ARG CUDA_VERSION=12.8.1
ARG UBUNTU_VERSION=24.04

# -----------------------------------------------------------------------------
# Fetch pinned source trees once so both build stages use the same revision.
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS source

ARG INLINE_STUDIO_REPO=https://github.com/inlineresearch/Inline-Studio.git
ARG INLINE_STUDIO_REF=v1.2.63
ARG POD_RUNTIME_REPO=https://github.com/markwelshboy/pod-runtime.git
ARG POD_RUNTIME_REF=main

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git git-lfs \
    && rm -rf /var/lib/apt/lists/* \
    && git lfs install --system

RUN git clone --filter=blob:none "${INLINE_STUDIO_REPO}" /src/Inline-Studio \
    && git -C /src/Inline-Studio fetch --depth 1 origin "${INLINE_STUDIO_REF}" \
    && git -C /src/Inline-Studio checkout --detach FETCH_HEAD \
    && git -C /src/Inline-Studio rev-parse HEAD > /src/INLINE_STUDIO_COMMIT

RUN git clone --filter=blob:none "${POD_RUNTIME_REPO}" /src/pod-runtime \
    && git -C /src/pod-runtime fetch --depth 1 origin "${POD_RUNTIME_REF}" \
    && git -C /src/pod-runtime checkout --detach FETCH_HEAD \
    && git -C /src/pod-runtime rev-parse HEAD > /src/POD_RUNTIME_COMMIT

# -----------------------------------------------------------------------------
# Build the browser SPA. Node does not enter the runtime image.
# -----------------------------------------------------------------------------
FROM node:22-bookworm-slim AS frontend-build

WORKDIR /src/Inline-Studio
COPY --from=source /src/Inline-Studio/ ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts \
    && npm run build:spa \
    && test -f dist-web/index.html

# -----------------------------------------------------------------------------
# Build the Python environment against CUDA. Compilers stay in this stage.
# -----------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu${UBUNTU_VERSION} AS python-build

ARG TORCH_INDEX=https://download.pytorch.org/whl/nightly/cu128
ARG TORCH_VER=2.12.0.dev20260308+cu128
ARG TORCHVISION_VER=0.26.0.dev20260308+cu128
ARG TORCHAUDIO_VER=2.11.0.dev20260308+cu128

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    VENV=/opt/venv

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      build-essential gcc g++ cmake ninja-build pkg-config \
      git git-lfs ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python3.12 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

COPY constraints.txt /opt/constraints.txt
COPY pip.conf /etc/pip.conf
COPY --from=source /src/Inline-Studio/core /src/Inline-Studio/core

ENV PIP_CONSTRAINT=/opt/constraints.txt \
    PIP_BUILD_CONSTRAINT=/opt/constraints.txt

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --upgrade "pip<25.2" "setuptools>=66.1,<82" "wheel>=0.38"

# Install the known-good CUDA/Torch stack first. The global constraints keep all
# later dependency resolution in the same CUDA world.
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
      --index-url "${TORCH_INDEX}" \
      "torch==${TORCH_VER}" \
      "torchvision==${TORCHVISION_VER}" \
      "torchaudio==${TORCHAUDIO_VER}"

# Inline Core + server + local generation + training. Multi-GPU/xDiT remains an
# opt-in build arg because xfuser is niche and can make otherwise useful builds fail.
ARG INSTALL_PARALLEL=false
RUN --mount=type=cache,target=/root/.cache/pip \
    if [ "${INSTALL_PARALLEL}" = "true" ]; then \
      pip install "/src/Inline-Studio/core[all,parallel]"; \
    else \
      pip install "/src/Inline-Studio/core[all]"; \
    fi \
    && pip install hf_transfer \
    && pip check

# -----------------------------------------------------------------------------
# Final/headless RunPod image.
# -----------------------------------------------------------------------------
FROM nvidia/cuda:${CUDA_VERSION}-cudnn-runtime-ubuntu${UBUNTU_VERSION} AS final

ARG BUILD_DATE=unknown
ARG VCS_REF=unknown
ARG IMAGE_VERSION=dev
ARG INLINE_STUDIO_REF=v1.2.63
ARG POD_RUNTIME_REF=main

LABEL org.opencontainers.image.title="Inline Studio for RunPod" \
      org.opencontainers.image.description="Headless Inline Studio GPU image with SSH and pod-runtime helpers" \
      org.opencontainers.image.source="https://github.com/markwelshboy/inline-studio" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.markwelshboy.inline-studio.ref="${INLINE_STUDIO_REF}" \
      io.markwelshboy.pod-runtime.ref="${POD_RUNTIME_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    VENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/pod-runtime/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    POD_RUNTIME_DIR=/opt/pod-runtime \
    INLINE_STATE_ROOT=/workspace/inline-studio \
    INLINE_HOST=0.0.0.0 \
    INLINE_PORT=8848 \
    INLINE_MODELS_DIR=/workspace/inline-studio/models \
    INLINE_DATA_DIR=/workspace/inline-studio/data \
    INLINE_EXTENSIONS_DIR=/workspace/inline-studio/extensions \
    INLINE_STUDIO_DATA_DIR=/workspace/inline-studio/studio-data \
    INLINE_STUDIO_WORKSPACE_DIR=/workspace/inline-studio/projects \
    INLINE_FRONTEND_ROOT=/opt/inline-studio/frontend \
    INLINE_LOG_DIR=/workspace/inline-studio/logs \
    HF_HOME=/workspace/huggingface \
    HUGGINGFACE_HUB_CACHE=/workspace/huggingface/hub \
    HF_XET_CACHE=/workspace/huggingface/xet \
    HF_XET_HIGH_PERFORMANCE=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    PIP_CONSTRAINT=/opt/constraints.txt \
    PIP_BUILD_CONSTRAINT=/opt/constraints.txt \
    PY=/opt/venv/bin/python \
    PIP=/opt/venv/bin/pip

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 \
      openssh-server \
      git git-lfs curl ca-certificates jq \
      ffmpeg aria2 rsync tmux unzip wget \
      vim less nano \
      libgl1 libglib2.0-0 libgomp1 libsndfile1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /var/run/sshd /workspace /opt/inline-studio/frontend \
    && git lfs install --system

COPY --from=python-build /opt/venv /opt/venv
COPY --from=python-build /opt/constraints.txt /opt/constraints.txt
COPY --from=frontend-build /src/Inline-Studio/dist-web/ /opt/inline-studio/frontend/
COPY --from=source /src/pod-runtime/ /opt/pod-runtime/
COPY --from=source /src/INLINE_STUDIO_COMMIT /opt/inline-studio/INLINE_STUDIO_COMMIT
COPY --from=source /src/POD_RUNTIME_COMMIT /opt/inline-studio/POD_RUNTIME_COMMIT

COPY src/start.sh /usr/local/bin/inline-studio-start
COPY src/bashrc /root/.bashrc
COPY src/bash_functions /root/.bash_functions

RUN chmod +x /usr/local/bin/inline-studio-start \
    && find /opt/pod-runtime/bin -maxdepth 1 -type f -name '*.py' -exec chmod +x {} + \
    && ln -sfn /opt/pod-runtime/bin/hff.py /usr/local/bin/hff \
    && ln -sfn /opt/pod-runtime/bin/hf_manifest_expand.py /usr/local/bin/hf_manifest_expand \
    && test -f /opt/inline-studio/frontend/index.html \
    && /opt/venv/bin/python -c "import inline_core, torch; print('Inline Core import OK; torch', torch.__version__)"

WORKDIR /workspace

EXPOSE 22 8848

HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${INLINE_PORT}/v1/health" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/inline-studio-start"]
