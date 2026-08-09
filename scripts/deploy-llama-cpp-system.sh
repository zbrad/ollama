#!/usr/bin/env bash
# Deploy a published llama.cpp tuned-builds release into a system Ollama
# installation (managed by systemd, listening on the standard port).
#
# Downloads a release published by zbrad/llama.cpp's tuned/package.sh
# matching this machine's GPU variant and CUDA toolkit version, then
# deploys it: copies binaries + shared libraries into a named subdirectory
# of the Ollama library path, symlinks llama-server so Ollama's binary
# search finds it. No local llama.cpp checkout or build required.
#
# Needs root (writes to /usr/local/lib/ollama). Requires an interactive
# terminal for sudo -- run this yourself, it cannot be run non-interactively.
#
# Release tag format: v<build-number>-<variant>-cu<XXX>, e.g. v10333-gb10-cu133
#
# Usage:
#   sudo ./scripts/deploy-llama-cpp-system.sh [OPTIONS]
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
# shellcheck source=lib/llama-cpp-release.sh
source "$SCRIPT_DIR/lib/llama-cpp-release.sh"

LLAMA_CPP_REPO="zbrad/llama.cpp"
OLLAMA_LIB_DIR="/usr/local/lib/ollama"
OLLAMA_TARGET_DIR="$OLLAMA_LIB_DIR/local_llama_cpp"
VARIANT=""
CUDA_VERSION=""
EXACT_TAG=""
DRY_RUN=false

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)            VARIANT="$2";            shift 2 ;;
        --cuda-version)       CUDA_VERSION="$2";        shift 2 ;;
        --tag)                EXACT_TAG="$2";           shift 2 ;;
        --ollama-target-dir)  OLLAMA_TARGET_DIR="$2";   shift 2 ;;
        --dry-run)            DRY_RUN=true;             shift   ;;
        --help|-h)            usage ;;
        *) llama_release_die "unknown option: $1" ;;
    esac
done

command -v gh >/dev/null 2>&1 || llama_release_die "gh (GitHub CLI) is required but not found on PATH"

llama_release_detect_variant
llama_release_detect_cuda
llama_release_resolve_tag

echo "Variant:      $VARIANT"
echo "CUDA version: $CUDA_VERSION ($CUDA_TAG)"
echo "Release:      $TAG"
echo "Deploy dir:   $OLLAMA_TARGET_DIR  (system, requires sudo)"
$DRY_RUN && echo "(dry run — no files written)"
echo

llama_release_fetch "$(mktemp -d)"
llama_release_copy_into "$LLAMA_CPP_SOURCE_DIR" "$OLLAMA_TARGET_DIR"

OLLAMA_SERVER="$OLLAMA_LIB_DIR/llama-server"
TARGET_SERVER="$OLLAMA_TARGET_DIR/llama-server"

echo
echo "Activating llama-server..."
if $DRY_RUN; then
    echo "[dry-run] cp -p $OLLAMA_SERVER ${OLLAMA_SERVER}.bak (if it exists and isn't already a symlink)"
    echo "[dry-run] ln -sf $TARGET_SERVER $OLLAMA_SERVER"
else
    if [[ -f "$OLLAMA_SERVER" && ! -L "$OLLAMA_SERVER" ]]; then
        cp -p "$OLLAMA_SERVER" "${OLLAMA_SERVER}.bak"
        echo "  backed up: ${OLLAMA_SERVER}.bak"
    fi
    ln -sf "$TARGET_SERVER" "$OLLAMA_SERVER"
    echo "  linked: $OLLAMA_SERVER -> $TARGET_SERVER"
fi

echo
echo "Done ($TAG). Restart Ollama to pick up the new binary:"
echo "  sudo systemctl restart ollama"
