#!/bin/bash
# tuned/release.sh <variant> [--preflight-only] — run the release gates for the tarball tuned/package.sh made.
# It NEVER publishes or tags. When every gate passes it writes a ready-marker (gpu_tuned_release_ready); then
# tuned/publish.sh <variant> publishes exactly what these gates saw, and refuses if HEAD, the notes or an asset changed.
#   tuned/build.sh -> tuned/full_test.sh -> tuned/package.sh -> tuned/smoke_test.sh
#   -> (review + commit the notes) -> this -> tuned/publish.sh.
#
# Gates: preflight (branch, HEAD == origin, gh, tag free, the paired llama.cpp release still exists and is for this
# variant and toolkit); a passing full_test.sh log newer than the binary the build made; then gpu_tuned_release_gates
# (tuned-common): clean tree, HEAD pushed, tarball matches its package-info and .sha256, made after the tests, a
# passing smoke test newer than it, only release notes changed since the package's commit, notes committed and not a
# DRAFT.
#
# One identity per release: the date label tuned/build.sh allocated, as the native tag
# v0.<date>.<seq>-<variant>-<cuda>, recorded in package-info.txt, so a notes-only commit after packaging does not
# change it. gh creates that tag on the tuned-builds head (at publish). The CUDA toolkit is chosen as in build.sh
# (CUDA_TAG / CUDA_VER).
#
#   CUDA_TAG=cu134 bash tuned/release.sh gb10      # gates; writes the ready-marker if all pass
#   CUDA_TAG=cu134 bash tuned/publish.sh gb10      # publishes from the marker
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=""
PREFLIGHT_ONLY=0
for arg in "$@"; do
    case "${arg}" in
        --preflight-only) PREFLIGHT_ONLY=1 ;;
        -*) echo "ERROR: unknown option ${arg}" >&2; exit 2 ;;
        *) VARIANT="${arg}" ;;
    esac
done
[[ -n "${VARIANT}" ]] || { echo "usage: tuned/release.sh <variant> [--preflight-only]" >&2; exit 2; }

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${VARIANT}" || exit 1
cd "${REPODIR}"

REPO="zbrad/ollama"
BRANCH="tuned-builds"
DIST_DIR="${OLLAMA_TUNED_DIST_DIR}"
PKG_INFO="${DIST_DIR}/package-info.txt"
READY_MARKER="${OLLAMA_TUNED_RELEASES_DIR}/RELEASE_READY_${GPU_TUNED_VARIANT}"
gpu_tuned_release_marker_clear "${READY_MARKER}"   # a failing run leaves no marker

# The build identity comes from the package, not HEAD: notes-only commits after packaging move HEAD.
BIN_TAG=""; BUILD_COMMIT=""; LLAMA_CPP_TAG=""
if [[ -f "${PKG_INFO}" ]]; then
    BIN_TAG="$(sed -n 's/^release_tag=//p' "${PKG_INFO}")"
    BUILD_COMMIT="$(sed -n 's/^build_commit=//p' "${PKG_INFO}")"
    LLAMA_CPP_TAG="$(sed -n 's/^llama_cpp_tag=//p' "${PKG_INFO}")"
fi

echo "===================================================="
echo "ollama ${GPU_TUNED_HW_LABEL} release gates  (never publishes)"
echo "===================================================="
echo "  Binary tag  : ${BIN_TAG:-<no package yet>}"
echo "  Commit      : ${BUILD_COMMIT:-<no package yet>}"
echo "  Paired with : ${LLAMA_CPP_TAG:-<no package yet>}"
echo "  CUDA        : ${CUDA_TAG}"
echo ""

# --- Preflight gates: run all of them, report every failure, then stop. ---
FAILURES=0
fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok:   $*"; }

echo "Preflight:"
if [[ -z "$(git status --porcelain)" ]]; then
    ok "working tree clean"
else
    fail "working tree is not clean (commit, stash or remove changes first)"
fi

if [[ "$(git rev-parse --abbrev-ref HEAD)" == "${BRANCH}" ]]; then
    ok "on branch ${BRANCH}"
else
    fail "not on branch ${BRANCH}"
fi

if git fetch origin "${BRANCH}" --tags --quiet 2>/dev/null; then
    if [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/${BRANCH}")" ]]; then
        ok "HEAD == origin/${BRANCH} (the release --target)"
    else
        fail "HEAD differs from origin/${BRANCH}; push or pull first"
    fi
else
    fail "could not fetch origin/${BRANCH}"
fi

if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
else
    fail "gh is not authenticated"
fi

if [[ -z "${BIN_TAG}" ]]; then
    fail "no package-info.txt, so no release tag; run tuned/package.sh ${VARIANT}"
elif ! gpu_tuned_check_release_tag "${BIN_TAG}" 2>/dev/null; then
    fail "release tag ${BIN_TAG} carries no date label (v0.<YYYYMMDD>.<seq>-<variant>-<cuda>)"
elif gh release view "${BIN_TAG}" --repo "${REPO}" >/dev/null 2>&1; then
    fail "binary release ${BIN_TAG} already exists"
else
    ok "binary release ${BIN_TAG} is free"
fi

# The pairing: the llama.cpp release this package was smoke-tested against must still be published, and be for this
# variant and toolkit. (A deleted pair would leave a release that names nothing a user can fetch.)
if [[ -z "${LLAMA_CPP_TAG}" ]]; then
    fail "package-info.txt names no llama_cpp_tag; run tuned/package.sh ${VARIANT}"
elif [[ "${LLAMA_CPP_TAG}" != v0.*-"${GPU_TUNED_VARIANT}-${CUDA_TAG}" ]]; then
    fail "the paired llama.cpp release ${LLAMA_CPP_TAG} is not a ${GPU_TUNED_VARIANT}-${CUDA_TAG} release"
elif gh release view "${LLAMA_CPP_TAG}" --repo "${OLLAMA_TUNED_LLAMA_CPP_REPO}" >/dev/null 2>&1; then
    ok "paired llama.cpp release ${LLAMA_CPP_TAG} still exists on ${OLLAMA_TUNED_LLAMA_CPP_REPO}"
else
    fail "paired llama.cpp release ${LLAMA_CPP_TAG} no longer exists on ${OLLAMA_TUNED_LLAMA_CPP_REPO}"
fi

if gpu_tuned_verify_toolkit >/dev/null; then
    ok "toolkit ${CUDA_TAG} verified: nvcc matches its definition (${CUDA_HOME})"
else
    fail "toolkit ${CUDA_TAG} does not match its definition; run gpu_tuned_verify_toolkit for details"
fi

if [[ ${PREFLIGHT_ONLY} -eq 1 ]]; then
    if [[ ${FAILURES} -gt 0 ]]; then
        echo "" >&2
        echo "ERROR: ${FAILURES} preflight gate(s) failed." >&2
        exit 1
    fi
    echo ""
    echo "Preflight passed (--preflight-only)."
    exit 0
fi

# --- Test freshness: the log must be newer than the binary the build made (compared against the build tree, not
#     the staged copy). The pass phrase and the rest are checked by gpu_tuned_release_gates below. ---
echo ""
echo "Gates:"
TARBALL=""
SMOKE_LOG="${OLLAMA_TUNED_RELEASES_DIR}/SMOKE_RESULTS_${GPU_TUNED_VARIANT}.log"
NOTES_FILE="tuned/releases/RELEASE_NOTES_${BIN_TAG#v}.md"
if [[ ! -f "${PKG_INFO}" ]]; then
    fail "${PKG_INFO} not found; run tuned/package.sh ${VARIANT}"
else
    TARBALL="${DIST_DIR}/$(sed -n 's/^tarball=//p' "${PKG_INFO}")"
    gpu_tuned_release_gates tag="${BIN_TAG}" variant="${GPU_TUNED_VARIANT}" cuda="${CUDA_TAG}" info="${PKG_INFO}" \
        test_log="${OLLAMA_TUNED_TEST_LOG}" "test_pass=Full test suite summary: go test passed" built="${OLLAMA_TUNED_BIN_DIR}/ollama" \
        tarball="${TARBALL}" smoke_log="${SMOKE_LOG}" notes="${NOTES_FILE}" packaged="${BUILD_COMMIT}" \
        || FAILURES=$((FAILURES + 1))
fi
if [[ ${FAILURES} -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${FAILURES} gate(s) failed (preflight, test, package, notes); nothing was tagged or published, no ready-marker written." >&2
    exit 1
fi

RELEASE_TITLE="ollama ${BIN_TAG#v} (${BUILD_COMMIT:0:8}) — ${GPU_TUNED_HW_LABEL} (${CUDA_TAG}), paired with llama.cpp ${LLAMA_CPP_TAG#v}"

echo ""
gpu_tuned_release_ready "${READY_MARKER}" "${REPO}" "${BIN_TAG}" "${RELEASE_TITLE}" "${NOTES_FILE}" \
    "${TARBALL}#$(basename "${TARBALL}")" \
    "${TARBALL}.sha256#$(basename "${TARBALL}").sha256" \
    "${OLLAMA_TUNED_TEST_LOG}#Full test suite results (${GPU_TUNED_VARIANT})" \
    "${SMOKE_LOG}#Package smoke test results (${GPU_TUNED_VARIANT})"
