#!/bin/bash
# tuned/package.sh <variant> — package the binary tuned/build.sh made (and tuned/full_test.sh tested) for ONE
# variant and ONE CUDA toolkit into tuned/build/<cuda-tag>/dist/ollama-0.<date>.<seq>-<variant>-<cuda>.tar.gz with a
# .sha256 sidecar and package-info.txt, then check the tarball as a consumer gets it (extract, version, build-info
# stamp, NEEDED libraries). It packages only: no tag, no publishing. tuned/release.sh gates and tuned/publish.sh
# publishes exactly these files, with the tracked release notes (a draft is written here if there is none).
#
# The tarball holds the Go binary and BUILD_INFO.json, nothing else. Ollama's own CMake-built native payload is
# deliberately NOT packaged: the zbrad/llama.cpp release this one is paired with provides llama-server and its
# libraries (docs/llama-cpp-release.md). The pairing is chosen here, once, and recorded: the newest llama.cpp
# release for this variant and toolkit (gpu_tuned_newest_release_tag, docs/ARCHITECTURE.md D1), or the one named in
# OLLAMA_TUNED_LLAMA_CPP_TAG. It goes into package-info.txt (llama_cpp_tag=), the binary's build info and the notes;
# tuned/smoke_test.sh runs the package against exactly that release, and tuned/release.sh checks it still exists.
#
#   CUDA_TAG=cu134 bash tuned/build.sh gb10 && CUDA_TAG=cu134 bash tuned/full_test.sh gb10
#   CUDA_TAG=cu134 bash tuned/package.sh gb10
#   CUDA_TAG=cu134 bash tuned/smoke_test.sh gb10
#   (review and commit the notes, remove the DRAFT banner)
#   CUDA_TAG=cu134 bash tuned/release.sh gb10        # gates only; never publishes
#   CUDA_TAG=cu134 bash tuned/publish.sh gb10        # publishes what the gates saw
set -euo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/package.sh <variant>}"
cd "${REPODIR}"

# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

BIN="${OLLAMA_TUNED_BIN_DIR}/ollama"
[[ -x "${BIN}" ]] || { echo "ERROR: ${BIN} not found. Run CUDA_TAG=${CUDA_TAG} bash tuned/build.sh ${GPU_TUNED_VARIANT} first." >&2; exit 1; }

# Release identity: the tag tuned/build.sh allocated and compiled into the binary. Read, checked, never recomputed.
[[ -f "${OLLAMA_TUNED_BUILD_ROOT}/release-label" && -f "${OLLAMA_TUNED_BUILD_ROOT}/build-commit" ]] \
    || { echo "ERROR: ${OLLAMA_TUNED_BUILD_ROOT} has no release-label/build-commit; the build did not finish. Run tuned/build.sh ${GPU_TUNED_VARIANT}." >&2; exit 1; }
RELEASE_TAG="$(head -1 "${OLLAMA_TUNED_BUILD_ROOT}/release-label")"
BUILD_COMMIT="$(head -1 "${OLLAMA_TUNED_BUILD_ROOT}/build-commit")"
gpu_tuned_check_release_tag "${RELEASE_TAG}" || exit 1
[[ "${RELEASE_TAG}" == v0.*-"${GPU_TUNED_VARIANT}-${CUDA_TAG}" ]] || { echo "ERROR: the build's release ${RELEASE_TAG} is not for ${GPU_TUNED_VARIANT}-${CUDA_TAG}." >&2; exit 1; }
[[ "${BUILD_COMMIT}" != *-dirty ]] || { echo "ERROR: the build was made from a dirty tree (${BUILD_COMMIT}); commit, then run tuned/build.sh again." >&2; exit 1; }
# The binary must come from HEAD, or from a commit that differs from HEAD only under tuned/ (packaging scripts,
# not source). Fails closed: a build commit git does not know cannot be checked (H6).
git cat-file -e "${BUILD_COMMIT}^{commit}" 2>/dev/null || { echo "ERROR: build commit ${BUILD_COMMIT} is not known to git, so it cannot be checked against HEAD." >&2; exit 1; }
outside_tuned="$(git diff --name-only "${BUILD_COMMIT}" HEAD | grep -v '^tuned/' || true)"
if [[ -n "${outside_tuned}" ]]; then
    echo "ERROR: files outside tuned/ differ between build commit ${BUILD_COMMIT} and HEAD; rebuild at HEAD." >&2
    echo "${outside_tuned}" | head -5 >&2
    exit 1
fi
OLLAMA_VERSION="0.0.0+tuned.${RELEASE_TAG#v0.}"
[[ "$("${BIN}" --version 2>&1 | sed -n 's/.*client version is //p' | head -1)" == "${OLLAMA_VERSION}" ]] \
    || { echo "ERROR: ${BIN} does not report ${OLLAMA_VERSION}; run tuned/build.sh ${GPU_TUNED_VARIANT}." >&2; exit 1; }

# The test log must exist and pass; release.sh checks it is newer than the build, this stops a package of an untested build early.
grep -q "Full test suite summary: go test passed" "${OLLAMA_TUNED_TEST_LOG}" 2>/dev/null \
    || { echo "ERROR: ${OLLAMA_TUNED_TEST_LOG} is missing or does not show a pass. Run tuned/full_test.sh ${GPU_TUNED_VARIANT}." >&2; exit 1; }

# --- The llama.cpp release this one is paired with ---
if [[ -n "${OLLAMA_TUNED_LLAMA_CPP_TAG:-}" ]]; then
    LLAMA_CPP_TAG="${OLLAMA_TUNED_LLAMA_CPP_TAG}"
    [[ "${LLAMA_CPP_TAG}" == v0.*-"${GPU_TUNED_VARIANT}-${CUDA_TAG}" ]] || { echo "ERROR: OLLAMA_TUNED_LLAMA_CPP_TAG=${LLAMA_CPP_TAG} is not a ${GPU_TUNED_VARIANT}-${CUDA_TAG} release." >&2; exit 1; }
else
    LLAMA_CPP_TAG="$(gh api "repos/${OLLAMA_TUNED_LLAMA_CPP_REPO}/releases?per_page=100" --jq '.[].tag_name' | gpu_tuned_newest_release_tag "${GPU_TUNED_VARIANT}" "${CUDA_TAG}")" \
        || { echo "ERROR: no ${GPU_TUNED_VARIANT}-${CUDA_TAG} release found on ${OLLAMA_TUNED_LLAMA_CPP_REPO} (or gh failed); an ollama release is bound to one." >&2; exit 1; }
fi
gh api "repos/${OLLAMA_TUNED_LLAMA_CPP_REPO}/releases/tags/${LLAMA_CPP_TAG}" --jq .tag_name >/dev/null \
    || { echo "ERROR: ${OLLAMA_TUNED_LLAMA_CPP_REPO} has no release ${LLAMA_CPP_TAG}." >&2; exit 1; }

DIST_DIR="${OLLAMA_TUNED_DIST_DIR}"
mkdir -p "${DIST_DIR}"
TARBALL="${DIST_DIR}/ollama-${RELEASE_TAG#v}.tar.gz"

echo "===================================================="
echo "ollama ${GPU_TUNED_HW_LABEL} Package"
echo "===================================================="
echo ""
echo "  Release   : ${RELEASE_TAG}"
echo "  Commit    : ${BUILD_COMMIT}"
echo "  CUDA      : ${CUDA_TAG}"
echo "  Pairs with: ${OLLAMA_TUNED_LLAMA_CPP_REPO} ${LLAMA_CPP_TAG}"
echo ""

# Remove the previous package first: package-info.txt is written last, only if every check passed (H2).
rm -f "${DIST_DIR}/package-info.txt" "${DIST_DIR}"/ollama-*.tar.gz "${DIST_DIR}"/ollama-*.tar.gz.sha256

# --- Stage a copy and stamp it; the build tree's binary is never rewritten, so it stays older than the test log (H3). ---
STAGE="$(mktemp -d)"
CHECK_DIR=""
trap 'rm -rf "${STAGE}" "${CHECK_DIR}"' EXIT
cp -p "${BIN}" "${STAGE}/ollama"
gpu_tuned_embed_build_info_json "${STAGE}/ollama" \
    package=ollama component=ollama "release=${RELEASE_TAG}" "variant=${GPU_TUNED_VARIANT}" "hardware=${GPU_TUNED_HW_LABEL}" \
    "cuda.tag=${CUDA_TAG}" "cuda.version=${CUDA_VER}" "go.version=$(go env GOVERSION)" \
    "deps.llama_cpp.source=${OLLAMA_TUNED_LLAMA_CPP_REPO}" "deps.llama_cpp.tag=${LLAMA_CPP_TAG}"
gpu_tuned_verify_build_info_json "${STAGE}/ollama" "release=${RELEASE_TAG}" "variant=${GPU_TUNED_VARIANT}" "cuda.tag=${CUDA_TAG}" "deps.llama_cpp.tag=${LLAMA_CPP_TAG}" >/dev/null || exit 1
# The same JSON, shipped beside the binary so installers and automation can read the release without readelf.
gpu_tuned_read_build_info "${STAGE}/ollama" > "${STAGE}/BUILD_INFO.json" || exit 1

echo "Packaging -> ${TARBALL}..."
tar -C "${STAGE}" -czf "${TARBALL}" .
echo "Tarball: $(basename "${TARBALL}") ($(du -sh "${TARBALL}" | awk '{print $1}'))"
SHA_FILE="${TARBALL}.sha256"
(cd "${DIST_DIR}" && sha256sum "$(basename "${TARBALL}")" > "$(basename "${SHA_FILE}")")
echo "Checksum: $(basename "${SHA_FILE}") ($(cut -d' ' -f1 "${SHA_FILE}"))"

# --- Check the tarball as a consumer gets it. Any failure leaves no package-info.txt, which release.sh requires.
#     A check that cannot run is a failure (H4). ---
echo ""
echo "Checking the tarball:"
PKG_FAILURES=0
pkg_fail() { echo "  FAIL: $*" >&2; PKG_FAILURES=$((PKG_FAILURES + 1)); }
pkg_ok() { echo "  ok:   $*"; }
gpu_tuned_verify_sha256_sidecar "${TARBALL}" && pkg_ok "sha256 sidecar matches" || pkg_fail "sha256 sidecar does not match"
CHECK_DIR="$(mktemp -d)"
tar -C "${CHECK_DIR}" -xzf "${TARBALL}"
listing="$(cd "${CHECK_DIR}" && find . -mindepth 1 | sort | tr '\n' ' ')"
[[ "${listing}" == "./BUILD_INFO.json ./ollama " ]] && pkg_ok "the tarball holds the binary and BUILD_INFO.json only" || pkg_fail "unexpected tarball contents: ${listing}"
reported="$("${CHECK_DIR}/ollama" --version 2>&1 | sed -n 's/.*client version is //p' | head -1)"
[[ "${reported}" == "${OLLAMA_VERSION}" ]] && pkg_ok "extracted ollama reports ${reported}" || pkg_fail "extracted ollama reports '${reported}', expected ${OLLAMA_VERSION}"
if gpu_tuned_verify_build_info_json "${CHECK_DIR}/ollama" "release=${RELEASE_TAG}" "variant=${GPU_TUNED_VARIANT}" "cuda.tag=${CUDA_TAG}" "deps.llama_cpp.tag=${LLAMA_CPP_TAG}" >/dev/null; then
    pkg_ok "the stamp reads back as ${RELEASE_TAG}, paired with ${LLAMA_CPP_TAG}"
else
    pkg_fail "the stamp on the extracted binary does not read back as this release"
fi
[[ "$(jq -r .release "${CHECK_DIR}/BUILD_INFO.json" 2>/dev/null)" == "${RELEASE_TAG}" ]] && pkg_ok "BUILD_INFO.json names ${RELEASE_TAG}" || pkg_fail "BUILD_INFO.json does not name ${RELEASE_TAG}"
# Dynamic libraries: the Go binary links libc and its companions only. Anything else (a CUDA, ggml or stock ollama
# library) would be a dependency this package does not ship.
needed="$(readelf -d "${CHECK_DIR}/ollama" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
stray="$(printf '%s\n' "${needed}" | grep -vE '^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux-[a-z0-9_-]+\.so\.[0-9]+)$' | grep -v '^$' || true)"
[[ -z "${stray}" ]] && pkg_ok "NEEDED: only libc and its companions ($(printf '%s' "${needed}" | tr '\n' ' '))" || pkg_fail "NEEDED libraries the package does not ship: $(printf '%s' "${stray}" | tr '\n' ' ')"
if ldd "${CHECK_DIR}/ollama" 2>&1 | grep -q 'not found'; then pkg_fail "unresolved dependency: $(ldd "${CHECK_DIR}/ollama" 2>&1 | grep 'not found' | head -1)"; else pkg_ok "ldd: every dependency resolves"; fi
if [[ ${PKG_FAILURES} -gt 0 ]]; then
    echo "ERROR: ${PKG_FAILURES} package check(s) failed; not releasable." >&2
    exit 1
fi

# What release.sh needs: the identity the binary was built with (release.sh runs after notes-only commits, when
# HEAD no longer matches it) and the pairing.
cat > "${DIST_DIR}/package-info.txt" <<INFO
tarball=$(basename "${TARBALL}")
release_tag=${RELEASE_TAG}
build_commit=${BUILD_COMMIT}
cuda_tag=${CUDA_TAG}
variant=${GPU_TUNED_VARIANT}
llama_cpp_tag=${LLAMA_CPP_TAG}
sha256=$(cut -d" " -f1 "${SHA_FILE}")
INFO

# --- Draft release notes, only if none exist yet. They are a tracked file, reviewed and committed (a notes-only
#     commit) before release.sh; the DRAFT line must be removed first. ---
NOTES_FILE="${REPODIR}/tuned/releases/RELEASE_NOTES_${RELEASE_TAG#v}.md"
if [[ -f "${NOTES_FILE}" ]]; then
    echo "Release notes exist: ${NOTES_FILE}"
else
    mkdir -p "${REPODIR}/tuned/releases"
    {
        echo "<!-- DRAFT — not yet published: review, then delete this line and commit -->"
        echo "The \`ollama\` Go binary of this fork (${GPU_TUNED_VARIANT}, ${CUDA_TAG}), carrying its GPU-discovery fixes on top of upstream (notably the symlink-resolution segfault fix, commit 4d97a0f5). It reports version \`${OLLAMA_VERSION}\`. Built for linux/$(go env GOARCH) with $(go version | awk '{print $3}'); it links libc and nothing else."
        echo ""
        echo "Paired with ${OLLAMA_TUNED_LLAMA_CPP_REPO} release \`${LLAMA_CPP_TAG}\`. This package carries no native payload: deploy that llama.cpp release alongside it for GPU support (docs/llama-cpp-release.md). The smoke test ran this package against that release; see the attached smoke log for what it covered."
        echo ""
        echo "Tested: \`go test ./...\` passed on this commit (log attached). Not run: the \`integration/\` tests (they need a running server, a GPU and downloaded models). The package was checked as extracted (sha256, version, build-info stamp, NEEDED libraries)."
    } > "${NOTES_FILE}"
    echo "Wrote a DRAFT: ${NOTES_FILE}"
fi

echo ""
echo "Packaged ${TARBALL}. Not released: run tuned/smoke_test.sh ${GPU_TUNED_VARIANT}, review/commit the notes, then tuned/release.sh ${GPU_TUNED_VARIANT}."
