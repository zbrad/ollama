#!/usr/bin/env bash
# Deploy a local llama.cpp build into an Ollama installation.
#
# Expects both projects to live as siblings under a common parent:
#   $GIT_ROOT/ollama       (this repo)
#   $GIT_ROOT/llama.cpp    (local llama.cpp build)
#
# The script copies llama-server, llama-quantize, and all shared libraries
# from the llama.cpp build into a named subdirectory of the Ollama library
# path, then symlinks llama-server so Ollama's binary search finds it.
#
# Usage:
#   sudo ./scripts/deploy-local-llama-cpp.sh [OPTIONS]
#
# Options:
#   --llama-cpp-source-dir DIR   Override llama.cpp build output dir
#                                (default: <GIT_ROOT>/llama.cpp/bin)
#   --ollama-target-dir DIR      Override destination directory
#                                (default: /usr/local/lib/ollama/local_llama_cpp)
#   --dry-run                    Print actions without executing
#   --help                       Show this help
#
# After deploying, restart the Ollama service:
#   sudo systemctl restart ollama

set -euo pipefail

# Resolve the common parent from this script's location inside the ollama repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GIT_ROOT="$(cd "$OLLAMA_ROOT/.." && pwd)"

LLAMA_CPP_SOURCE_DIR="$GIT_ROOT/llama.cpp/bin"
OLLAMA_TARGET_DIR="/usr/local/lib/ollama/local_llama_cpp"
OLLAMA_LIB_DIR="/usr/local/lib/ollama"
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
        --llama-cpp-source-dir) LLAMA_CPP_SOURCE_DIR="$2"; shift 2 ;;
        --ollama-target-dir)    OLLAMA_TARGET_DIR="$2";    shift 2 ;;
        --dry-run)              DRY_RUN=true;              shift   ;;
        --help|-h)              usage ;;
        *) die "unknown option: $1" ;;
    esac
done

echo "GIT_ROOT:              $GIT_ROOT"
echo "LLAMA_CPP_SOURCE_DIR:  $LLAMA_CPP_SOURCE_DIR"
echo "OLLAMA_TARGET_DIR:     $OLLAMA_TARGET_DIR"
$DRY_RUN && echo "(dry run — no files written)"
echo

[[ -d "$LLAMA_CPP_SOURCE_DIR" ]] || die "llama.cpp build output not found: $LLAMA_CPP_SOURCE_DIR"
[[ -x "$LLAMA_CPP_SOURCE_DIR/llama-server" ]] || die "llama-server not found in: $LLAMA_CPP_SOURCE_DIR"

# Step 1: Create the target subdirectory and copy everything into it.
# Ollama discovers GPU backends by globbing $OLLAMA_LIB_DIR/*/ggml-* —
# having libggml-cuda.so here triggers discovery of this backend dir.
run mkdir -p "$OLLAMA_TARGET_DIR"

copy_real() {
    local src="$1" dst="$2"
    [[ -L "$src" ]] && return 0
    run cp -p "$src" "$dst/"
    echo "  copied: $(basename "$src")"
}

echo "Copying binaries..."
for bin in llama-server llama-quantize; do
    [[ -f "$LLAMA_CPP_SOURCE_DIR/$bin" ]] && copy_real "$LLAMA_CPP_SOURCE_DIR/$bin" "$OLLAMA_TARGET_DIR"
done

echo "Copying shared libraries..."
# For each versioned .so.X.Y.Z file, follow the .so.0 symlink in the source
# dir to confirm it's the canonical version — skip stale build artifacts.
for lib in "$LLAMA_CPP_SOURCE_DIR"/lib*.so.*; do
    [[ -f "$lib" ]] || continue
    [[ -L "$lib" ]] && continue

    lib_name=$(basename "$lib")

    # If this looks like a versioned file (lib*.so.X.Y.Z), verify it's current.
    if [[ "$lib_name" =~ \.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        link_name="${lib_name%.[0-9]*.[0-9]*.[0-9]*}.0"
        link_path="$LLAMA_CPP_SOURCE_DIR/$link_name"
        if [[ -L "$link_path" ]]; then
            link_target=$(readlink "$link_path")
            [[ "$link_target" == "$lib_name" ]] || continue
        fi
    fi

    copy_real "$lib" "$OLLAMA_TARGET_DIR"

    # Also install under the 0.0.0 version name that Ollama's installed
    # symlinks resolve to (Ollama's ExternalProject normalises X.Y.Z → 0.0.0).
    if [[ "$lib_name" =~ \.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        normalized=$(echo "$lib_name" | sed 's/\.[0-9]*\.[0-9]*\.[0-9]*$/.0.0.0/')
        if [[ "$normalized" != "$lib_name" ]]; then
            run cp -p "$OLLAMA_TARGET_DIR/$lib_name" "$OLLAMA_TARGET_DIR/$normalized"
            echo "  normalized: $lib_name -> $normalized"
        fi
    fi
done

# Step 2: Symlink the Ollama-wide llama-server to our binary.
# FindLlamaServer() in Ollama's Go code searches LibOllamaPath directly
# (/usr/local/lib/ollama/llama-server), not in subdirectories. Pointing
# it at our binary ensures the compat shim in libllama.so is the one used.
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
echo "Done. Restart Ollama to pick up the new binary:"
echo "  sudo systemctl restart ollama"
