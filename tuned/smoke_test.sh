#!/bin/bash
# tuned/smoke_test.sh <variant> — run the PACKAGED tarball against the llama.cpp release it is paired with, before
# anything is released. Stage order: build -> full_test -> package -> (this) -> release.
#
# It extracts tuned/package.sh's tarball and the paired zbrad/llama.cpp release (package-info.txt: llama_cpp_tag) into a
# scratch directory laid out as scripts/install-tuned.sh lays them out (bin/ollama, lib/ollama/local_llama_cpp/,
# lib/ollama/llama-server), starts `ollama serve` there on an unused loopback port with HOME and OLLAMA_MODELS
# in scratch (nothing in ~/.ollama or ~/.local is touched, no system service is stopped), and checks:
#   1. the tarball's sha256 matches package-info.txt and its .sha256 sidecar;
#   2. the extracted binary reports this release, its build-info stamp names this release, variant, toolkit and
#      paired llama.cpp tag, and BUILD_INFO.json is that same stamp;
#   3. `ollama serve` comes up and /api/version reports this release;
#   4. GPU discovery through the paired llama-server completes ("inference compute" is logged for a CUDA device) and
#      the server does not crash or log a discovery failure -- the failure the fork's discovery fixes exist for.
# What it does not do: load a model or generate text (the paired llama.cpp release's own smoke test covers its
# inference). A smoke test, not the suite: tuned/full_test.sh ran `go test ./...`. Needs the network for the paired
# release (~200 MB, cached per tag under tuned/build/<cuda-tag>/llama-cpp/). Writes
# tuned/build/<cuda-tag>/releases/SMOKE_RESULTS_<variant>.log; tuned/release.sh requires a passing log newer than the
# tarball, and a pass needs the end marker, so an abort cannot pass.
set -uo pipefail

REPODIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GPU_TUNED_ARG_VARIANT="${1:?usage: tuned/smoke_test.sh <variant>}"
# shellcheck source=env.sh
source "${REPODIR}/tuned/env.sh" "${GPU_TUNED_ARG_VARIANT}" || exit 1

DIST_DIR="${OLLAMA_TUNED_DIST_DIR}"
INFO="${DIST_DIR}/package-info.txt"
mkdir -p "${OLLAMA_TUNED_RELEASES_DIR}"
LOG="${OLLAMA_TUNED_RELEASES_DIR}/SMOKE_RESULTS_${GPU_TUNED_VARIANT}.log"
[[ -f "${INFO}" ]] || { echo "ERROR: ${INFO} not found. Run CUDA_TAG=${CUDA_TAG} bash tuned/package.sh ${GPU_TUNED_VARIANT} first." >&2; exit 1; }
info() { sed -n "s/^$1=//p" "${INFO}"; }
TARBALL="${DIST_DIR}/$(info tarball)"; WANT_SHA="$(info sha256)"; RELEASE_TAG="$(info release_tag)"; LLAMA_CPP_TAG="$(info llama_cpp_tag)"
OLLAMA_VERSION="0.0.0+tuned.${RELEASE_TAG#v0.}"
[[ -f "${TARBALL}" ]] || { echo "ERROR: ${TARBALL} not found." >&2; exit 1; }
[[ -n "${LLAMA_CPP_TAG}" ]] || { echo "ERROR: ${INFO} names no llama_cpp_tag; package again." >&2; exit 1; }
rm -f "${LOG}"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    [[ -z "${SERVER_PID}" ]] || kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${WORK}"
}
trap cleanup EXIT
FAILS=0
ok() { echo "  ok:   $*"; }
fail() { echo "  FAIL: $*"; FAILS=$((FAILS + 1)); }

# The paired llama.cpp release, one directory per tag so a different tag is never reused (D1). The tarball's
# sidecar is verified after download.
LLAMA_DIR="${OLLAMA_TUNED_BUILD_ROOT}/llama-cpp/${LLAMA_CPP_TAG}"
fetch_llama_cpp() {
    [[ -f "${LLAMA_DIR}/.release_tag" && "$(cat "${LLAMA_DIR}/.release_tag")" == "${LLAMA_CPP_TAG}" && -x "${LLAMA_DIR}/extracted/llama-server-tuned" ]] && return 0
    local dl="${LLAMA_DIR}/download"
    mkdir -p "${dl}"
    gh release download "${LLAMA_CPP_TAG}" --repo "${OLLAMA_TUNED_LLAMA_CPP_REPO}" --pattern 'llama-cpp-*.tar.gz' --pattern 'llama-cpp-*.tar.gz.sha256' --dir "${dl}" --clobber || return 1
    local tgz
    tgz="$(ls "${dl}"/llama-cpp-*.tar.gz | head -1)" || return 1
    gpu_tuned_verify_sha256_sidecar "${tgz}" || return 1
    rm -rf "${LLAMA_DIR}/extracted"
    mkdir -p "${LLAMA_DIR}/extracted"
    tar -C "${LLAMA_DIR}/extracted" -xzf "${tgz}" || return 1
    [[ -x "${LLAMA_DIR}/extracted/llama-server-tuned" ]] || return 1
    printf '%s\n' "${LLAMA_CPP_TAG}" > "${LLAMA_DIR}/.release_tag"
}

{
    # This block is a pipeline subshell, which does not inherit the parent's EXIT trap: stop the server here.
    trap '[[ -z "${SERVER_PID}" ]] || kill "${SERVER_PID}" 2>/dev/null' EXIT
    echo "ollama package smoke test -- variant=${GPU_TUNED_VARIANT} cuda=${CUDA_VER} (${CUDA_TAG})"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "release: ${RELEASE_TAG}"
    echo "tarball: $(basename "${TARBALL}")"
    echo "paired:  ${OLLAMA_TUNED_LLAMA_CPP_REPO} ${LLAMA_CPP_TAG}"
    echo "not run: model load and text generation"
    echo ""

    got="$(sha256sum "${TARBALL}" | awk '{print $1}')"
    [[ "${got}" == "${WANT_SHA}" ]] && ok "sha256 matches package-info.txt (${got:0:12}...)" || fail "sha256 ${got} != package-info.txt ${WANT_SHA}"
    gpu_tuned_verify_sha256_sidecar "${TARBALL}" && ok "sidecar .sha256 verifies" || fail "sidecar .sha256 does not verify"

    PREFIX="${WORK}/prefix"
    mkdir -p "${PREFIX}/bin" "${PREFIX}/lib/ollama/local_llama_cpp"
    mkdir -p "${WORK}/ex"
    tar -C "${WORK}/ex" -xzf "${TARBALL}" && cp -p "${WORK}/ex/ollama" "${PREFIX}/bin/ollama" \
        && ok "extracted the tarball" || fail "could not extract the tarball"

    reported="$("${PREFIX}/bin/ollama" --version 2>&1 | sed -n 's/.*client version is //p' | head -1)"
    [[ "${reported}" == "${OLLAMA_VERSION}" ]] && ok "extracted ollama reports ${reported}" || fail "extracted ollama reports '${reported}', expected ${OLLAMA_VERSION}"
    if gpu_tuned_verify_build_info_json "${PREFIX}/bin/ollama" "release=${RELEASE_TAG}" "variant=${GPU_TUNED_VARIANT}" "cuda.tag=${CUDA_TAG}" "deps.llama_cpp.tag=${LLAMA_CPP_TAG}" >/dev/null; then
        ok "build-info stamp reads back as ${RELEASE_TAG}, ${GPU_TUNED_VARIANT}, ${CUDA_TAG}, paired with ${LLAMA_CPP_TAG}"
    else
        fail "build-info stamp does not read back as this release"
    fi
    [[ "$(gpu_tuned_read_build_info "${PREFIX}/bin/ollama" | jq -S -c . 2>/dev/null)" == "$(jq -S -c . "${WORK}/ex/BUILD_INFO.json" 2>/dev/null)" ]] \
        && ok "BUILD_INFO.json is the binary's own stamp" || fail "BUILD_INFO.json differs from the binary's stamp"

    if fetch_llama_cpp; then
        ok "paired llama.cpp release ${LLAMA_CPP_TAG} is present and its sidecar verified"
    else
        fail "could not fetch the paired llama.cpp release ${LLAMA_CPP_TAG}"
    fi
    if [[ -x "${LLAMA_DIR}/extracted/llama-server-tuned" ]]; then
        cp -a "${LLAMA_DIR}/extracted/." "${PREFIX}/lib/ollama/local_llama_cpp/"
        # As scripts/install-tuned.sh does: the release ships llama-server-tuned, Ollama looks for llama-server.
        ln -sf local_llama_cpp/llama-server-tuned "${PREFIX}/lib/ollama/llama-server"
    fi

    # Serve from the scratch prefix. Port: an unused loopback one chosen by the kernel.
    PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
    mkdir -p "${WORK}/home" "${WORK}/models"
    SERVER_LOG="${WORK}/serve.log"
    env -i PATH="/usr/bin:/bin" HOME="${WORK}/home" OLLAMA_HOST="127.0.0.1:${PORT}" OLLAMA_MODELS="${WORK}/models" \
        OLLAMA_DEBUG=1 LD_LIBRARY_PATH="${GPU_TUNED_TOOLKIT_LIB_DIR}" \
        "${PREFIX}/bin/ollama" serve > "${SERVER_LOG}" 2>&1 &
    SERVER_PID=$!
    served=""
    for _ in $(seq 1 60); do
        served="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/api/version" 2>/dev/null || true)"
        [[ -n "${served}" ]] && break
        kill -0 "${SERVER_PID}" 2>/dev/null || break
        sleep 1
    done
    if [[ "$(printf '%s' "${served}" | jq -r .version 2>/dev/null)" == "${OLLAMA_VERSION}" ]]; then
        ok "ollama serve is up on 127.0.0.1:${PORT} and /api/version reports ${OLLAMA_VERSION}"
    else
        fail "/api/version did not report ${OLLAMA_VERSION} (got: ${served:-nothing}); serve is $(kill -0 "${SERVER_PID}" 2>/dev/null && echo running || echo not running)"
    fi

    # Discovery runs at startup; give it time to finish, then read what it logged.
    for _ in $(seq 1 60); do
        grep -q 'inference compute\|failure during llama-server GPU discovery' "${SERVER_LOG}" && break
        kill -0 "${SERVER_PID}" 2>/dev/null || break
        sleep 1
    done
    if grep -q 'inference compute' "${SERVER_LOG}" && grep 'inference compute' "${SERVER_LOG}" | grep -qi 'library=CUDA'; then
        ok "GPU discovery through the paired llama-server completed: $(grep 'inference compute' "${SERVER_LOG}" | head -1 | sed 's/^.*msg="inference compute"//' | cut -c1-160)"
    else
        fail "no CUDA device was logged by GPU discovery"
    fi
    if grep -qiE 'failure during llama-server GPU discovery|panic:|SIGSEGV|segmentation' "${SERVER_LOG}"; then
        fail "the server log shows a discovery failure or crash: $(grep -iE 'failure during llama-server GPU discovery|panic:|SIGSEGV|segmentation' "${SERVER_LOG}" | head -1 | cut -c1-200)"
    else
        ok "no discovery failure, panic or segfault in the server log"
    fi
    kill -0 "${SERVER_PID}" 2>/dev/null && ok "the server is still running after discovery" || fail "the server exited"
    kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
    echo "  (server log tail)"; tail -n 6 "${SERVER_LOG}" | cut -c1-200 | sed 's/^/  | /'

    echo ""
    if [[ ${FAILS} -eq 0 ]]; then
        echo "=== Smoke test summary: passed ==="
    else
        echo "=== Smoke test summary: FAILED (${FAILS}) ==="
    fi
    echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} 2>&1 | tee "${LOG}"
grep -q '^=== Smoke test summary: passed ===$' "${LOG}"
