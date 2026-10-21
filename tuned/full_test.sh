#!/bin/bash
# tuned/full_test.sh <variant> — run the Go test suite of this fork for the build tuned/build.sh made for ONE
# variant and ONE CUDA toolkit, and write a results log in that toolkit's tree.
#
#   CUDA_TAG=cu134 bash tuned/full_test.sh gb10
#
# The log is tuned/build/<cuda-tag>/releases/TEST_RESULTS_<variant>.log and ends with a "Full test suite
# summary" line. tuned/release.sh refuses to pass its gates unless that log shows a pass and is newer than the
# binary tuned/build.sh built.
#
# What runs: `go test -count=1 ./...` over every package of the module, at the commit the build was made from
# (go test compiles its own test binaries; it does not run the shipped binary, which tuned/smoke_test.sh runs
# from the package). What does not run, and is named in the log header: the tests under integration/ carry the
# `integration` build tag, need a running server, a GPU and downloaded models, and are not part of the default
# suite upstream either. That scope is a recorded decision for the owner (docs/ARCHITECTURE.md G3), not a default.
set -uo pipefail

GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/full_test.sh <variant>}"
REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPODIR}" || exit 1

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

[[ -x "${OLLAMA_TUNED_BIN_DIR}/ollama" && -f "${OLLAMA_TUNED_BUILD_ROOT}/release-label" ]] \
    || { echo "ERROR: no finished build in ${OLLAMA_TUNED_BUILD_ROOT}. Run CUDA_TAG=${CUDA_TAG} bash tuned/build.sh ${GPU_TUNED_VARIANT} first." >&2; exit 1; }
BUILD_COMMIT="$(cat "${OLLAMA_TUNED_BUILD_ROOT}/build-commit")"
[[ "${BUILD_COMMIT}" != *-dirty ]] || { echo "ERROR: the build was made from a dirty tree (${BUILD_COMMIT}); commit, then run tuned/build.sh again." >&2; exit 1; }
# The suite tests the working tree; it must be the source the binary came from (tuned/ may differ).
outside_tuned="$(git diff --name-only "${BUILD_COMMIT}" -- . ':!tuned' 2>/dev/null || echo '?')"
[[ -z "${outside_tuned}" ]] || {
    echo "ERROR: files outside tuned/ differ between the build commit ${BUILD_COMMIT} and the working tree; run tuned/build.sh again." >&2
    echo "${outside_tuned}" | head -5 >&2
    exit 1
}

mkdir -p "${OLLAMA_TUNED_RELEASES_DIR}"
RESULTS_FILE="${OLLAMA_TUNED_TEST_LOG}"
{
    echo "ollama full test suite -- variant=${GPU_TUNED_VARIANT} cuda=${CUDA_VER} (${CUDA_TAG})"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "commit:  ${BUILD_COMMIT}"
    echo "release: $(cat "${OLLAMA_TUNED_BUILD_ROOT}/release-label")"
    echo "go:      $(go version)"
    echo "tests:   go test -count=1 ./... (every package of the module)"
    echo "skipped: integration/ (build tag integration: needs a running server, a GPU and downloaded models)"
    echo ""
} > "${RESULTS_FILE}"

# pipefail: the exit status below must be go test's, not tee's.
set -o pipefail
go test -count=1 ./... 2>&1 | tee -a "${RESULTS_FILE}"
STATUS=$?

{
    echo ""
    echo "packages ok: $(grep -c '^ok' "${RESULTS_FILE}")   FAIL lines: $(grep -c '^FAIL' "${RESULTS_FILE}")   no test files: $(grep -c 'no test files' "${RESULTS_FILE}")"
    if [ "${STATUS}" -eq 0 ]; then
        echo "=== Full test suite summary: go test passed ==="
    else
        echo "=== Full test suite summary: go test FAILED (exit ${STATUS}) ==="
    fi
    echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee -a "${RESULTS_FILE}"
echo "Results written to ${RESULTS_FILE}"
exit "${STATUS}"
