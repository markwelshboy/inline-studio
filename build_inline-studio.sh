#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage:
  ./build_inline-studio.sh [options]

Build/output:
  --builder <name>           Buildx builder; default: buildkit-scratch
  --no-push                 Build/cache only; do not push or load into Docker
  --load                    Load into local Docker instead of pushing
  --platform <platforms>    Default: linux/amd64
  --no-cache                Disable build cache
  --prune                   Prune stopped containers and dangling Docker images
  --prune-hard              Aggressively prune selected Buildx builder cache

Tagging:
  --image <repo/name>       Default: markwelshboy/inline-studio
  --tag <tag>               Default: latest
  --image-version <value>   OCI version label; default: 1.0.0

Source/runtime pins:
  --inline-ref <ref>        Default: v1.2.63
  --pod-runtime-ref <ref>   Default: main
  --parallel                Install Inline Core's xDiT/xfuser extra

Other:
  --dockerfile <path>       Default: Dockerfile
  --build-arg KEY=VALUE     Additional build arg; repeatable
  -h, --help                Show this help

Examples:
  ./build_inline-studio.sh
  ./build_inline-studio.sh --tag v1.2.63
  ./build_inline-studio.sh --no-push
  ./build_inline-studio.sh --load --tag test
  ./build_inline-studio.sh --inline-ref main --no-cache
  ./build_inline-studio.sh --parallel
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

IMAGE=markwelshboy/inline-studio
TAG=latest
IMAGE_VERSION=1.0.0
DOCKERFILE=Dockerfile
PLATFORM=linux/amd64
BUILDER="${BUILDX_BUILDER:-buildkit-scratch}"
INLINE_REF=v1.2.63
POD_RUNTIME_REF=main
PUSH=true
LOAD=false
NO_CACHE=false
PRUNE=false
PRUNE_HARD=false
INSTALL_PARALLEL=false
EXTRA_BUILD_ARGS=()

while (($#)); do
  case "$1" in
    --builder) [[ -n "${2:-}" ]] || die '--builder requires a value'; BUILDER="$2"; shift 2 ;;
    --no-push) PUSH=false; shift ;;
    --load) LOAD=true; PUSH=false; shift ;;
    --platform) [[ -n "${2:-}" ]] || die '--platform requires a value'; PLATFORM="$2"; shift 2 ;;
    --no-cache) NO_CACHE=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --prune-hard) PRUNE_HARD=true; shift ;;
    --image) [[ -n "${2:-}" ]] || die '--image requires a value'; IMAGE="$2"; shift 2 ;;
    --tag) [[ -n "${2:-}" ]] || die '--tag requires a value'; TAG="$2"; shift 2 ;;
    --image-version) [[ -n "${2:-}" ]] || die '--image-version requires a value'; IMAGE_VERSION="$2"; shift 2 ;;
    --inline-ref) [[ -n "${2:-}" ]] || die '--inline-ref requires a value'; INLINE_REF="$2"; shift 2 ;;
    --pod-runtime-ref) [[ -n "${2:-}" ]] || die '--pod-runtime-ref requires a value'; POD_RUNTIME_REF="$2"; shift 2 ;;
    --parallel) INSTALL_PARALLEL=true; shift ;;
    --dockerfile) [[ -n "${2:-}" ]] || die '--dockerfile requires a value'; DOCKERFILE="$2"; shift 2 ;;
    --build-arg) [[ -n "${2:-}" ]] || die '--build-arg requires KEY=VALUE'; EXTRA_BUILD_ARGS+=(--build-arg "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

have docker || die 'docker is not installed'
docker info >/dev/null 2>&1 || die 'Docker is not accessible as the current user'
docker buildx version >/dev/null 2>&1 || die 'docker buildx is unavailable'
docker buildx inspect "${BUILDER}" >/dev/null 2>&1 || die "Buildx builder '${BUILDER}' not found or unavailable"
[[ -f "$DOCKERFILE" ]] || die "Dockerfile not found: $DOCKERFILE"

if $LOAD && [[ "$PLATFORM" == *,* ]]; then
  die '--load supports a single platform only'
fi

if $PRUNE_HARD; then
  docker buildx prune --builder "${BUILDER}" --all --force || true
elif $PRUNE; then
  docker container prune -f || true
  docker image prune -f || true
fi

BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  VCS_REF="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
else
  VCS_REF=unknown
fi

ARGS=(
  --builder "${BUILDER}"
  --target final
  --platform "$PLATFORM"
  --file "$DOCKERFILE"
  --tag "${IMAGE}:${TAG}"
  --build-arg "BUILD_DATE=${BUILD_DATE}"
  --build-arg "VCS_REF=${VCS_REF}"
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION}"
  --build-arg "INLINE_STUDIO_REF=${INLINE_REF}"
  --build-arg "POD_RUNTIME_REF=${POD_RUNTIME_REF}"
  --build-arg "INSTALL_PARALLEL=${INSTALL_PARALLEL}"
)

$NO_CACHE && ARGS+=(--no-cache)
if $PUSH; then
  ARGS+=(--push)
elif $LOAD; then
  ARGS+=(--load)
fi

ARGS+=("${EXTRA_BUILD_ARGS[@]}")
ARGS+=(.)

cat <<SUMMARY
== Inline Studio image build ==
Image            : ${IMAGE}:${TAG}
Builder          : ${BUILDER}
Platform         : ${PLATFORM}
Push             : ${PUSH}
Load             : ${LOAD}
Inline ref       : ${INLINE_REF}
pod-runtime ref  : ${POD_RUNTIME_REF}
Parallel/xDiT    : ${INSTALL_PARALLEL}
Image version    : ${IMAGE_VERSION}
VCS ref          : ${VCS_REF}
Build date       : ${BUILD_DATE}
Dockerfile       : ${DOCKERFILE}
SUMMARY

echo
echo '== Storage before =='
docker system df || true
docker buildx du --builder "${BUILDER}" || true
df -h /var /srv/buildkit 2>/dev/null || true

docker buildx build "${ARGS[@]}"

if $PUSH; then
  printf '\nPushed: %s:%s\n' "$IMAGE" "$TAG"
elif $LOAD; then
  printf '\nBuilt and loaded locally: %s:%s\n' "$IMAGE" "$TAG"
else
  printf '\nBuilt successfully; result was not pushed or loaded and remains in BuildKit cache.\n'
fi

echo
echo '== Storage after =='
docker system df || true
docker buildx du --builder "${BUILDER}" || true
df -h /var /srv/buildkit 2>/dev/null || true
