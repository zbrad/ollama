#!/usr/bin/env bash
# Fetch a published llama.cpp tuned-builds release and deploy it into an
# Ollama installation.
#
# Supersedes deploy-local-llama-cpp.sh's local-sibling-checkout approach:
# instead of requiring a local $GIT_ROOT/llama.cpp build, this downloads a
# release tarball published by zbrad/llama.cpp's tuned/package.sh (see that
# repo's tuned/ directory) matching this machine's GPU variant and CUDA
# toolkit version, then deploys it the same way (copy binaries + shared
# libraries into a named subdirectory of the Ollama library path, symlink
# llama-server into place).
#
# Release tag format: v<build-number>-<variant>-cu<XXX>
#   e.g. v10333-gb10-cu133
#
# Usage:
#   sudo ./scripts/fetch-llama-cpp-release.sh [OPTIONS]
#
# Options:
#   --variant NAME            Override detected GPU variant (gb10/rtx40/rtx50)
#   --cuda-version X.Y        Override detected CUDA toolkit version
#   --tag TAG                 Fetch an exact release tag instead of auto-matching
#   --ollama-target-dir DIR   Override destination directory
#                             (default: /usr/local/lib/ollama/local_llama_cpp)
#   --dry-run                 Print actions without executing
#   --help                    Show this help
#
# After deploying, restart the Ollama service:
#   sudo systemctl restart ollama

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_LIB_DIR="/usr/local/lib/ollama"
OLLAMA_TARGET_DIR="$OLLAMA_LIB_DIR/local_llama_cpp"
LLAMA_CPP_REPO="zbrad/llama.cpp"
VARIANT=""
CUDA_VERSION=""
EXACT_TAG=""
DRY_RUN=false

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

die() { echo "error: $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)            VARIANT="$2";            shift 2 ;;
        --cuda-version)       CUDA_VERSION="$2";        shift 2 ;;
        --tag)                EXACT_TAG="$2";           shift 2 ;;
        --ollama-target-dir)  OLLAMA_TARGET_DIR="$2";   shift 2 ;;
        --dry-run)            DRY_RUN=true;             shift   ;;
        --help|-h)            usage ;;
        *) die "unknown option: $1" ;;
    esac
done

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required but not found on PATH"

# --- Detect GPU variant from nvidia-smi, unless overridden ---
if [[ -z "$VARIANT" ]]; then
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    case "$gpu_name" in
        *GB10*)    VARIANT="gb10" ;;
        *RTX*40*)  VARIANT="rtx40" ;;
        *RTX*50*)  VARIANT="rtx50" ;;
        *) die "could not auto-detect GPU variant from nvidia-smi output ('$gpu_name'); pass --variant explicitly" ;;
    esac
fi

# --- Detect CUDA toolkit version, unless overridden ---
# Prefer nvcc (actual installed toolkit); fall back to nvidia-smi's reported
# max-supported CUDA version if nvcc isn't present (e.g. a runtime-only
# inference host with no dev toolkit installed).
if [[ -z "$CUDA_VERSION" ]]; then
    if command -v nvcc >/dev/null 2>&1; then
        CUDA_VERSION="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
    fi
    if [[ -z "$CUDA_VERSION" ]]; then
        CUDA_VERSION="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}')"
    fi
    [[ -n "$CUDA_VERSION" ]] || die "could not auto-detect CUDA version (nvcc/nvidia-smi both failed); pass --cuda-version explicitly"
fi
CUDA_TAG="cu${CUDA_VERSION//./}"
CUDA_MAJOR="${CUDA_VERSION%%.*}"

echo "Variant:      $VARIANT"
echo "CUDA version: $CUDA_VERSION ($CUDA_TAG)"
echo

# --- Resolve the release tag to fetch ---
if [[ -n "$EXACT_TAG" ]]; then
    TAG="$EXACT_TAG"
else
    # List all tags matching this variant, any CUDA version: v<build>-<variant>-cu<XXX>
    mapfile -t candidates < <(
        gh release list --repo "$LLAMA_CPP_REPO" --limit 200 2>/dev/null \
            | awk -F'\t' '{print $3}' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+$" || true
    )
    [[ "${#candidates[@]}" -gt 0 ]] || die "no releases found on $LLAMA_CPP_REPO matching variant '$VARIANT' (tag pattern v<N>-${VARIANT}-cu<XXX>)"

    # Exact CUDA match first, highest build number wins.
    TAG="$(
        for t in "${candidates[@]}"; do
            [[ "$t" == *"-${CUDA_TAG}" ]] && echo "$t"
        done | sort -t- -k1.2 -n | tail -1
    )"

    # No exact match: fall back to the highest build number among releases
    # whose CUDA major matches and toolkit version is <= this host's (CUDA's
    # runtime ABI is forward-compatible within a major series only).
    if [[ -z "$TAG" ]]; then
        TAG="$(
            for t in "${candidates[@]}"; do
                t_cuda_tag="${t##*-cu}"
                t_major="${t_cuda_tag:0:2}"
                t_minor="${t_cuda_tag:2}"
                [[ "$t_major" == "$CUDA_MAJOR" ]] || continue
                # Compare t_minor <= this host's minor digit(s) lexically is
                # unsafe for multi-digit minors; compare numerically instead.
                host_minor="${CUDA_VERSION#*.}"
                if (( 10#$t_minor <= 10#$host_minor )); then
                    echo "$t"
                fi
            done | sort -t- -k1.2 -n | tail -1
        )"
        [[ -n "$TAG" ]] && echo "NOTE: no exact CUDA ${CUDA_VERSION} release for ${VARIANT}; falling back to $TAG (CUDA runtime ABI is forward-compatible within a major series)."
    fi

    [[ -n "$TAG" ]] || die "no release found on $LLAMA_CPP_REPO matching variant '$VARIANT' and CUDA major ${CUDA_MAJOR}.x (candidates: ${candidates[*]})"
fi

echo "Resolved release: $TAG"
$DRY_RUN && echo "(dry run — no files written)"
echo

# --- Download + extract ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if $DRY_RUN; then
    echo "[dry-run] gh release download $TAG --repo $LLAMA_CPP_REPO --dir $WORK_DIR"
    echo "[dry-run] tar -xzf <asset> -C $WORK_DIR/extracted"
    LLAMA_CPP_SOURCE_DIR="$WORK_DIR/extracted"
    mkdir -p "$LLAMA_CPP_SOURCE_DIR"
else
    gh release download "$TAG" --repo "$LLAMA_CPP_REPO" --dir "$WORK_DIR" --clobber
    asset="$(find "$WORK_DIR" -maxdepth 1 -name '*.tar.gz' | head -1)"
    [[ -n "$asset" ]] || die "no .tar.gz asset found in release $TAG"
    LLAMA_CPP_SOURCE_DIR="$WORK_DIR/extracted"
    mkdir -p "$LLAMA_CPP_SOURCE_DIR"
    tar -xzf "$asset" -C "$LLAMA_CPP_SOURCE_DIR"
fi

[[ $DRY_RUN == true || -x "$LLAMA_CPP_SOURCE_DIR/llama-server" ]] || die "llama-server not found after extracting $TAG"

# --- Deploy (same logic as deploy-local-llama-cpp.sh, simplified: a
#     freshly extracted release tarball has exactly one clean version of
#     each file, no stale duplicates or symlinks to filter). ---
run mkdir -p "$OLLAMA_TARGET_DIR"

echo "Copying binaries..."
for bin in llama-server llama-quantize; do
    if [[ -f "$LLAMA_CPP_SOURCE_DIR/$bin" ]]; then
        run cp -p "$LLAMA_CPP_SOURCE_DIR/$bin" "$OLLAMA_TARGET_DIR/"
        echo "  copied: $bin"
    fi
done

echo "Copying shared libraries..."
for lib in "$LLAMA_CPP_SOURCE_DIR"/lib*.so.*; do
    [[ -f "$lib" ]] || continue
    lib_name="$(basename "$lib")"
    run cp -p "$lib" "$OLLAMA_TARGET_DIR/"
    echo "  copied: $lib_name"

    if [[ "$lib_name" =~ \.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        normalized="$(echo "$lib_name" | sed 's/\.[0-9]*\.[0-9]*\.[0-9]*$/.0.0.0/')"
        if [[ "$normalized" != "$lib_name" ]]; then
            run cp -p "$OLLAMA_TARGET_DIR/$lib_name" "$OLLAMA_TARGET_DIR/$normalized"
            echo "  normalized: $lib_name -> $normalized"
        fi
    fi
done

OLLAMA_SERVER="$OLLAMA_LIB_DIR/llama-server"
TARGET_SERVER="$OLLAMA_TARGET_DIR/llama-server"

echo
echo "Activating llama-server..."
if [[ -f "$OLLAMA_SERVER" && ! -L "$OLLAMA_SERVER" ]]; then
    run cp -p "$OLLAMA_SERVER" "${OLLAMA_SERVER}.bak"
    echo "  backed up: ${OLLAMA_SERVER}.bak"
fi
run ln -sf "$TARGET_SERVER" "$OLLAMA_SERVER"
echo "  linked: $OLLAMA_SERVER -> $TARGET_SERVER"

echo
echo "Done ($TAG). Restart Ollama to pick up the new binary:"
echo "  sudo systemctl restart ollama"
