#!/bin/bash
# tuned/package.sh — build the `ollama` Go binary from this fork (carrying
# our GPU-discovery fixes, e.g. commit 4d97a0f5's segfault fix) and publish
# it as a GitHub release, so a fresh machine can fetch a working `ollama`
# binary without a git clone/Go toolchain of its own.
#
# Ollama's own CMake-built native payload (build/lib/ollama/ -- CPU backend
# variants, etc.) is deliberately NOT packaged here: zbrad/llama.cpp's own
# tuned-builds release already provides a complete, self-contained native
# payload (llama-server + matched-version libggml-base/cpu/cuda/llama) that
# supersedes it for this GPU-enabled deployment flow. This script packages
# only the Go binary itself, which has no meaningful native dependencies
# (confirmed via `ldd`: just libc) and no GPU-variant axis of its own --
# only CPU architecture (GOARCH) matters for it.
#
# Usage:
#   bash tuned/package.sh
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPODIR}"

GOARCH="$(go env GOARCH)"
GOOS="$(go env GOOS)"
[[ "${GOOS}" == "linux" ]] || { echo "ERROR: tuned/package.sh only supports linux (got ${GOOS})" >&2; exit 1; }

# Same build-identity derivation as zbrad/llama.cpp's tuned/env.sh, for the
# same reason: a release tag should match what the binary itself reports.
# Respect pre-set overrides for the same reason too (re-packaging an
# already-built binary after a tooling-only commit shouldn't require a
# rebuild just to keep the tag accurate).
: "${OLLAMA_TUNED_BUILD_NUMBER:=$(git rev-list --count HEAD)}"
: "${OLLAMA_TUNED_BUILD_COMMIT:=$(git rev-parse --short HEAD)}"

echo "===================================================="
echo "ollama (${GOARCH}) Package"
echo "===================================================="
echo ""
echo "  Build : ${OLLAMA_TUNED_BUILD_NUMBER} (${OLLAMA_TUNED_BUILD_COMMIT})"
echo "  Arch  : ${GOARCH}"
echo ""

OLLAMA_VERSION="0.0.0+tuned.${OLLAMA_TUNED_BUILD_NUMBER}.${OLLAMA_TUNED_BUILD_COMMIT}"
LDFLAGS="-s -w -X=github.com/ollama/ollama/version.Version=${OLLAMA_VERSION} -X=github.com/ollama/ollama/server.mode=release"

echo "Building (go build -ldflags \"${LDFLAGS}\")..."
go build -trimpath -ldflags "${LDFLAGS}" -o "${REPODIR}/ollama" .

BINARY_VERSION="$("${REPODIR}/ollama" --version 2>&1 | grep -o 'client version is .*' || true)"
echo "  Built binary reports: ${BINARY_VERSION}"

DIST_DIR="${REPODIR}/dist"
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"
TARBALL="${DIST_DIR}/ollama-${OLLAMA_TUNED_BUILD_NUMBER}-${GOARCH}.tar.gz"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -p "${REPODIR}/ollama" "${STAGE}/"

echo ""
echo "Packaging -> ${TARBALL}..."
tar -C "${STAGE}" -czf "${TARBALL}" .
echo "Tarball: $(basename "${TARBALL}") ($(du -sh "${TARBALL}" | awk '{print $1}'))"

RELEASE_TAG="v${OLLAMA_TUNED_BUILD_NUMBER}-${GOARCH}"
RELEASE_TITLE="ollama ${OLLAMA_TUNED_BUILD_NUMBER} (${OLLAMA_TUNED_BUILD_COMMIT}) — ${GOARCH}"

echo ""
echo "Publishing to GitHub release ${RELEASE_TAG}..."
gh release create "${RELEASE_TAG}" \
    --repo zbrad/ollama \
    --title "${RELEASE_TITLE}" \
    --target "tuned-builds" \
    --notes "ollama Go binary only (no native payload -- deploy zbrad/llama.cpp's own tuned-builds release alongside it for GPU support, see docs/llama-cpp-release.md). Carries this fork's GPU-discovery fixes on top of upstream (notably the symlink-resolution segfault fix, commit 4d97a0f5). Built for ${GOARCH}/linux." \
    "${TARBALL}#$(basename "${TARBALL}")"

echo ""
echo "Done: https://github.com/zbrad/ollama/releases/tag/${RELEASE_TAG}"
