#!/bin/bash
# tuned/env.sh <variant> — single source of truth for a tuned ollama build's variant, toolkit and output layout.
# Source this file with the variant as $1; do not execute it directly.
#
# ollama ships a Go binary. It has no GPU code and no CUDA dependency of its own: it runs the llama-server of a
# zbrad/llama.cpp release, and the fork's GPU-discovery fixes only matter against that. So an ollama release is
# BOUND to a llama.cpp release (owner decision 2026-10-21): it is built, tested and tagged for one variant and one
# CUDA toolkit, the ones of the llama.cpp release it pairs with, and the toolkit is used here only to name that
# pair, never to compile. The ollama release has its own date label (from this checkout's HEAD); the llama.cpp
# tag it was paired with is recorded in package-info.txt, the build info and the release notes.
#
#   CUDA_TAG=cu134 bash tuned/build.sh gb10     (or CUDA_VER=13.4)
#
# The toolkit comes from the vendored definitions in tuned/common-data/toolkits/<id>.env (zbrad/tuned-common),
# never from /usr/local/cuda or from whatever happens to be installed. There is no default: CUDA_TAG or CUDA_VER
# must name one. Repo-specific settings live in tuned/repo.env, loaded last; it may not change any shared key.

GPU_TUNED_ARG_VARIANT="$1"
if [[ -z "${GPU_TUNED_ARG_VARIANT}" ]]; then
    echo "ERROR: env.sh requires a variant argument (gb10, rtx40 or rtx50)" >&2
    return 1 2>/dev/null || exit 1
fi

GPU_TUNED_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_TUNED_DATA_DIR="${GPU_TUNED_SELF_DIR}/common-data"
# shellcheck source=common-data/devices/gb10.conf
source "${GPU_TUNED_DATA_DIR}/devices/${GPU_TUNED_ARG_VARIANT}.conf" || return 1 2>/dev/null || exit 1
export GPU_TUNED_VARIANT GPU_TUNED_PLATFORM GPU_TUNED_CUDA_ARCH GPU_TUNED_HW_LABEL

# shellcheck source=common.sh
source "${GPU_TUNED_SELF_DIR}/common.sh" || return 1 2>/dev/null || exit 1

gpu_tuned_assert_platform "${GPU_TUNED_PLATFORM}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1

# The binary's CPU architecture is the variant's platform: a gb10 release is arm64, rtx40/rtx50 are amd64.
command -v go >/dev/null 2>&1 || { echo "[tuned/env] ERROR: go not found on PATH." >&2; return 1 2>/dev/null || exit 1; }
OLLAMA_TUNED_GOARCH="$(go env GOARCH)"
case "${GPU_TUNED_PLATFORM}:${OLLAMA_TUNED_GOARCH}" in
    aarch64:arm64|x86_64:amd64) ;;
    *) echo "[tuned/env] ERROR: go builds for ${OLLAMA_TUNED_GOARCH}, but ${GPU_TUNED_VARIANT} is ${GPU_TUNED_PLATFORM}." >&2; return 1 2>/dev/null || exit 1 ;;
esac
[[ "$(go env GOOS)" == linux ]] || { echo "[tuned/env] ERROR: tuned ollama builds are linux only (go builds for $(go env GOOS))." >&2; return 1 2>/dev/null || exit 1; }

REPODIR="$(cd "${GPU_TUNED_SELF_DIR}/.." && pwd)"
# Build identity: the commit the binary is built from. Not the identity of a release (that is the date label
# build.sh allocates); a pre-set value is respected so a tooling-only commit does not force a rebuild check.
: "${OLLAMA_TUNED_BUILD_COMMIT:=$(git -C "${REPODIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
export OLLAMA_TUNED_BUILD_COMMIT OLLAMA_TUNED_GOARCH

# --- Toolkit: named by CUDA_TAG (cu134) or CUDA_VER (13.4), never defaulted or guessed (docs/ARCHITECTURE.md B4).
#     Exports CUDA_VER, CUDA_TAG, CUDA_HOME. ---
gpu_tuned_select_toolkit "${GPU_TUNED_DATA_DIR}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1

# --- Repo-specific settings, loaded last; may not change any shared device/toolkit key. ---
gpu_tuned_load_repo_env "${GPU_TUNED_SELF_DIR}/repo.env" || return 1 2>/dev/null || exit 1
export GPU_TUNED_UPSTREAM_REF

# --- Output layout: one tree per toolkit, tuned/build/<cuda-tag>/ (gitignored), with no variant level
#     (docs/ARCHITECTURE.md C2): bin/ (the built binary, never the repo-root ./ollama a local run may use),
#     dist/ (tarball, sidecar, package-info.txt), releases/ (generated test and smoke logs; the tracked
#     RELEASE_NOTES_*.md stay in tuned/releases/), llama-cpp/<tag>/ (the paired llama.cpp release the smoke test
#     extracts). The claim refuses a tree last used by another variant. ---
GPU_TUNED_REPO_ROOT="${REPODIR}"
gpu_tuned_claim_toolkit_tree "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}" || return 1 2>/dev/null || exit 1
OLLAMA_TUNED_BUILD_ROOT="${GPU_TUNED_REPO_ROOT}/tuned/build/${CUDA_TAG}"
OLLAMA_TUNED_BIN_DIR="${OLLAMA_TUNED_BUILD_ROOT}/bin"
OLLAMA_TUNED_DIST_DIR="$(gpu_tuned_out_dir dist "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")"
OLLAMA_TUNED_RELEASES_DIR="$(gpu_tuned_out_dir releases "${GPU_TUNED_REPO_ROOT}" "${CUDA_TAG}" "${GPU_TUNED_VARIANT}")"
OLLAMA_TUNED_TEST_LOG="${OLLAMA_TUNED_RELEASES_DIR}/TEST_RESULTS_${GPU_TUNED_VARIANT}.log"
OLLAMA_TUNED_LLAMA_CPP_REPO="zbrad/llama.cpp"
export OLLAMA_TUNED_BUILD_ROOT OLLAMA_TUNED_BIN_DIR OLLAMA_TUNED_DIST_DIR OLLAMA_TUNED_RELEASES_DIR OLLAMA_TUNED_TEST_LOG OLLAMA_TUNED_LLAMA_CPP_REPO
