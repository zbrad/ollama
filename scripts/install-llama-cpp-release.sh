#!/usr/bin/env bash
# Install a published llama.cpp tuned-builds release into a system Ollama
# installation, on any machine — no git clone of this repo required.
#
#   curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/install-llama-cpp-release.sh | bash
#
# Self-contained (unlike deploy-llama-cpp-system.sh, which sources
# scripts/lib/llama-cpp-release.sh by relative path — that only works from
# a real checkout, not piped into bash where $0/BASH_SOURCE don't resolve
# to a real file with siblings). Fetches the release tarball with plain
# curl, not `gh`, so it has no dependency beyond curl/tar/bash — works on
# a fresh machine that doesn't have the GitHub CLI installed or authed.
#
# Same detection/matching/deploy logic as deploy-llama-cpp-system.sh; keep
# the two in sync if either changes. Auto-elevates via sudo if not already
# root (same convention as this repo's own scripts/install.sh).
#
# Env overrides: LLAMA_CPP_VARIANT, LLAMA_CPP_CUDA_VERSION, LLAMA_CPP_TAG,
# OLLAMA_TARGET_DIR (default /usr/local/lib/ollama/local_llama_cpp).

set -euo pipefail

LLAMA_CPP_REPO="zbrad/llama.cpp"
OLLAMA_LIB_DIR="/usr/local/lib/ollama"
OLLAMA_TARGET_DIR="${OLLAMA_TARGET_DIR:-$OLLAMA_LIB_DIR/local_llama_cpp}"
VARIANT="${LLAMA_CPP_VARIANT:-}"
CUDA_VERSION="${LLAMA_CPP_CUDA_VERSION:-}"
EXACT_TAG="${LLAMA_CPP_TAG:-}"

status() { echo ">>> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required but not found"
command -v tar >/dev/null 2>&1 || die "tar is required but not found"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "not running as root and sudo not found"
    SUDO="sudo"
fi

# --- Detect GPU variant ---
if [ -z "$VARIANT" ]; then
    command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi not found; pass LLAMA_CPP_VARIANT=gb10|rtx40|rtx50 explicitly"
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    case "$gpu_name" in
        *GB10*)   VARIANT="gb10" ;;
        *RTX*40*) VARIANT="rtx40" ;;
        *RTX*50*) VARIANT="rtx50" ;;
        *) die "could not auto-detect GPU variant from nvidia-smi output ('$gpu_name'); pass LLAMA_CPP_VARIANT explicitly" ;;
    esac
fi

# --- Verify CPU architecture matches the variant ---
# Each variant is only built for one CPU architecture -- gb10 is DGX Spark
# (aarch64); rtx40/rtx50 are consumer desktop/laptop parts (x86_64). Fail
# before downloading anything if this machine doesn't match, rather than
# fetching a release tarball built for the wrong architecture.
machine_arch="$(uname -m)"
case "$VARIANT" in
    gb10)        expected_arch="aarch64" ;;
    rtx40|rtx50) expected_arch="x86_64" ;;
    *)           expected_arch="" ;;
esac
if [ -n "$expected_arch" ] && [ "$machine_arch" != "$expected_arch" ]; then
    die "architecture mismatch: this machine is $machine_arch, but variant '$VARIANT' releases are built for $expected_arch (set LLAMA_CPP_VARIANT explicitly if auto-detection got this wrong)"
fi

# --- Detect CUDA toolkit version ---
if [ -z "$CUDA_VERSION" ]; then
    if command -v nvcc >/dev/null 2>&1; then
        CUDA_VERSION="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
    fi
    if [ -z "$CUDA_VERSION" ]; then
        CUDA_VERSION="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}')"
    fi
    [ -n "$CUDA_VERSION" ] || die "could not auto-detect CUDA version; pass LLAMA_CPP_CUDA_VERSION explicitly"
fi
CUDA_TAG="cu${CUDA_VERSION//./}"
CUDA_MAJOR="${CUDA_VERSION%%.*}"

status "Variant:      $VARIANT"
status "CUDA version: $CUDA_VERSION ($CUDA_TAG)"

# --- Resolve release tag via the public GitHub API (no auth needed for a public repo) ---
if [ -z "$EXACT_TAG" ]; then
    candidates="$(
        curl -fsSL "https://api.github.com/repos/${LLAMA_CPP_REPO}/releases?per_page=100" \
            | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/.*"tag_name": *"\([^"]*\)"/\1/' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+\$" || true
    )"
    [ -n "$candidates" ] || die "no releases found on $LLAMA_CPP_REPO matching variant '$VARIANT' (tag pattern v<N>-${VARIANT}-cu<XXX>)"

    TAG="$(echo "$candidates" | grep -- "-${CUDA_TAG}\$" | sort -t- -k1.2 -n | tail -1 || true)"

    if [ -z "$TAG" ]; then
        TAG="$(
            echo "$candidates" | while read -r t; do
                t_cuda="${t##*-cu}"
                t_major="${t_cuda:0:2}"
                t_minor="${t_cuda:2}"
                [ "$t_major" = "$CUDA_MAJOR" ] || continue
                host_minor="${CUDA_VERSION#*.}"
                if [ "$((10#$t_minor))" -le "$((10#$host_minor))" ]; then
                    echo "$t"
                fi
            done | sort -t- -k1.2 -n | tail -1
        )"
        [ -n "$TAG" ] && status "NOTE: no exact CUDA ${CUDA_VERSION} release for ${VARIANT}; falling back to $TAG"
    fi
    [ -n "$TAG" ] || die "no release found matching variant '$VARIANT' and CUDA major ${CUDA_MAJOR}.x (candidates: $candidates)"
else
    TAG="$EXACT_TAG"
fi

status "Release:      $TAG"
status "Deploy dir:   $OLLAMA_TARGET_DIR"

# --- Download + extract ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ASSET_URL="https://github.com/${LLAMA_CPP_REPO}/releases/download/${TAG}/$(
    curl -fsSL "https://api.github.com/repos/${LLAMA_CPP_REPO}/releases/tags/${TAG}" \
        | grep -o '"name": *"[^"]*\.tar\.gz"' | sed 's/.*"name": *"\([^"]*\)"/\1/' | head -1 || true
)"
status "Downloading $ASSET_URL"
curl -fsSL "$ASSET_URL" -o "$WORK_DIR/release.tar.gz"

SOURCE_DIR="$WORK_DIR/extracted"
mkdir -p "$SOURCE_DIR"
tar -xzf "$WORK_DIR/release.tar.gz" -C "$SOURCE_DIR"
[ -x "$SOURCE_DIR/llama-server" ] || die "llama-server not found after extracting $TAG"

# --- Deploy ---
$SUDO mkdir -p "$OLLAMA_TARGET_DIR"

status "Copying binaries..."
for bin in llama-server llama-quantize; do
    [ -f "$SOURCE_DIR/$bin" ] && $SUDO cp -p "$SOURCE_DIR/$bin" "$OLLAMA_TARGET_DIR/"
done

status "Copying shared libraries..."
for lib in "$SOURCE_DIR"/lib*.so "$SOURCE_DIR"/lib*.so.*; do
    [ -f "$lib" ] || continue
    lib_name="$(basename "$lib")"
    $SUDO cp -p "$lib" "$OLLAMA_TARGET_DIR/"
    case "$lib_name" in
        *.[0-9]*.[0-9]*.[0-9]*)
            normalized="$(echo "$lib_name" | sed -E 's/\.[0-9]+\.[0-9]+\.[0-9]+$/.0.0.0/')"
            [ "$normalized" != "$lib_name" ] && $SUDO cp -p "$OLLAMA_TARGET_DIR/$lib_name" "$OLLAMA_TARGET_DIR/$normalized"
            ;;
    esac
done

OLLAMA_SERVER="$OLLAMA_LIB_DIR/llama-server"
TARGET_SERVER="$OLLAMA_TARGET_DIR/llama-server"

status "Activating llama-server..."
if [ -f "$OLLAMA_SERVER" ] && [ ! -L "$OLLAMA_SERVER" ]; then
    $SUDO cp -p "$OLLAMA_SERVER" "${OLLAMA_SERVER}.bak"
    status "  backed up: ${OLLAMA_SERVER}.bak"
fi
$SUDO ln -sf "$TARGET_SERVER" "$OLLAMA_SERVER"

status "Done ($TAG). Restart Ollama to pick up the new binary:"
status "  sudo systemctl restart ollama"
