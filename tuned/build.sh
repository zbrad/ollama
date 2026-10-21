#!/bin/bash
# tuned/build.sh <variant> — build the ollama Go binary from this fork (it carries the GPU-discovery fixes, e.g.
# commit 4d97a0f5's segfault fix) for ONE variant and ONE CUDA toolkit, the pair of the llama.cpp release it will
# be released with (tuned/env.sh). The binary goes to tuned/build/<cuda-tag>/bin/ollama, never the repo-root
# ./ollama.
#
#   CUDA_TAG=cu134 bash tuned/build.sh gb10     (or CUDA_VER=13.4)
#
# Stage order (docs/ARCHITECTURE.md B3): build.sh -> full_test.sh -> package.sh -> smoke_test.sh ->
# (review and commit the release notes) -> release.sh -> publish.sh.
#
# The release label (E3/E4) is allocated here, at the stage that bakes it into the binary (`ollama --version`
# prints it): the UTC date of HEAD's commit plus the lowest sequence not yet taken by a tag (GPU_TUNED_LABEL_SEQ=<n>
# chooses it offline). The tag is v0.<date>.<seq>-<variant>-<cuda>. release-label and build-commit are written
# last, so their presence means the build finished; package.sh and release.sh read them and never recompute them.
#
# ollama's native payload (the CMake-built backends under build/lib/ollama) is deliberately not built: the
# zbrad/llama.cpp release this one is paired with provides llama-server and its libraries. Only the Go binary is
# built; it links libc and nothing else (package.sh checks that).
set -euo pipefail

GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/build.sh <variant>}"
REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPODIR}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

LABEL="$(gpu_tuned_allocate_date_label "${REPODIR}")" || exit 1
RELEASE_TAG="$(gpu_tuned_native_tag "${GPU_TUNED_VARIANT}" "${CUDA_TAG}" "${LABEL}")" || exit 1
# What `ollama --version` reports: upstream's 0.0.0 development version (the server compares versions, so the
# base stays as it was) with the release label as build metadata. The tag, not this string, is the identity.
OLLAMA_VERSION="0.0.0+tuned.${RELEASE_TAG#v0.}"
LDFLAGS="-s -w -X=github.com/ollama/ollama/version.Version=${OLLAMA_VERSION} -X=github.com/ollama/ollama/server.mode=release"

echo "===================================================="
echo "ollama ${GPU_TUNED_HW_LABEL} build"
echo "===================================================="
echo "  Release   : ${RELEASE_TAG}"
echo "  Version   : ${OLLAMA_VERSION}"
echo "  Commit    : ${OLLAMA_TUNED_BUILD_COMMIT}"
echo "  Pair      : ${GPU_TUNED_VARIANT} ${CUDA_TAG} (the llama.cpp release is chosen at package time)"
echo "  Go        : $(go version)"
echo "  Output    : ${OLLAMA_TUNED_BIN_DIR}/ollama"
echo ""

# Remove the previous build's markers and binary first: they are rewritten only if this build succeeds.
rm -f "${OLLAMA_TUNED_BUILD_ROOT}/build-commit" "${OLLAMA_TUNED_BUILD_ROOT}/release-label" "${OLLAMA_TUNED_BIN_DIR}/ollama"
mkdir -p "${OLLAMA_TUNED_BIN_DIR}"

echo "Building (go build -trimpath -ldflags \"${LDFLAGS}\")..."
go build -trimpath -ldflags "${LDFLAGS}" -o "${OLLAMA_TUNED_BIN_DIR}/ollama" .

BINARY_VERSION="$("${OLLAMA_TUNED_BIN_DIR}/ollama" --version 2>&1 | sed -n 's/.*client version is //p' | head -1)"
[[ "${BINARY_VERSION}" == "${OLLAMA_VERSION}" ]] || {
    echo "ERROR: the built binary reports '${BINARY_VERSION}', expected '${OLLAMA_VERSION}'." >&2
    exit 1
}
echo "  Built binary reports: ${BINARY_VERSION}"

# build-commit: the source the binary was made from. A dirty tree is recorded as such and package.sh refuses it.
BUILD_COMMIT="$(git rev-parse HEAD)"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || BUILD_COMMIT="${BUILD_COMMIT}-dirty"
printf '%s\n' "${RELEASE_TAG}" > "${OLLAMA_TUNED_BUILD_ROOT}/release-label"
printf '%s\n' "${BUILD_COMMIT}" > "${OLLAMA_TUNED_BUILD_ROOT}/build-commit"

echo ""
echo "Built:        ${OLLAMA_TUNED_BIN_DIR}/ollama ($(du -sh "${OLLAMA_TUNED_BIN_DIR}/ollama" | awk '{print $1}'))"
echo "Release:      ${RELEASE_TAG}"
echo "Build commit: ${BUILD_COMMIT}"
echo "Next: CUDA_TAG=${CUDA_TAG} bash tuned/full_test.sh ${GPU_TUNED_VARIANT}"
