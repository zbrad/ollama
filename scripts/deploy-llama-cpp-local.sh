#!/usr/bin/env bash
# Deploy a published llama.cpp tuned-builds release into this repo's own
# dev-layout build directory — no sudo, no system files touched, no
# interference with a system-installed Ollama.
#
# Ollama's own binary-search logic (llm/llama_binary.go, ml/path.go)
# already checks "<cwd>/build/lib/ollama/" for a llama-server binary
# before falling back to /usr/local paths — this script deploys there
# specifically so a locally-built `./ollama serve` (run from this repo's
# root) picks up the tuned llama-server automatically.
#
# GPU backend libraries are discovered separately, by globbing
# "<lib-ollama-root>/*/ggml-*" (any SUBDIRECTORY containing a ggml-* file
# becomes a candidate backend) -- so libggml-cuda.so must live one level
# deep, not flat alongside llama-server. This mirrors
# deploy-llama-cpp-system.sh's structure exactly (local_llama_cpp/
# subdirectory + a symlinked llama-server), just rooted under this repo's
# build/lib/ollama/ instead of /usr/local/lib/ollama/.
#
# FIXED (2026-08-10): Ollama's own GPU-discovery subprocess used to segfault
# in this local-mode layout. Root cause (llm/llama_server.go): llama-server
# is found via a symlink AT build/lib/ollama itself, but the library-path
# builder derived llamaDir from that *unresolved* symlink path -- making it
# equal build/lib/ollama instead of the local_llama_cpp/ dir the real
# binary lives in, which broke the "skip dirs already covered by llamaDir"
# dedup and let Ollama's own (differently-versioned) common libs load ahead
# of the deployed build's matching set, crashing when a GPU backend .so
# loaded against the wrong ggml-base already resident. Fixed by resolving
# symlinks before deriving llamaDir. Verified end-to-end with real
# inference, not just discovery logs -- see tuned-builds-expansion-plan.md
# (project -home-zbrad-gh) for the full writeup.
#
# Separately (non-blocking, unrelated): newer llama.cpp "router mode"
# (triggered when llama-server is started with no model, as Ollama's
# discovery does) skips per-device compute-capability reporting by design
# -- falls back to unfiltered CUDA arch matching with a warning; worth
# knowing about if you see that warning in the logs.
#
# Runs Ollama on an alternate port by default (not 11434), so it can run
# side by side with a system Ollama instance and be reused as a fixed,
# known target for integration tests.
#
# Usage:
#   ./scripts/deploy-llama-cpp-local.sh [OPTIONS]
#
# Options:
#   --variant NAME         Override detected GPU variant (gb10/rtx40/rtx50)
#   --cuda-version X.Y     Override detected CUDA toolkit version
#   --tag TAG              Fetch an exact release tag instead of auto-matching
#   --port PORT            Port for OLLAMA_HOST (default: 11435)
#   --serve                Also launch `./ollama serve` in the foreground
#                          after deploying (Ctrl-C to stop)
#   --dry-run              Print actions without executing
#   --help                 Show this help
#
# Without --serve, deploy only and print the command to start serving:
#   OLLAMA_HOST=127.0.0.1:11435 ./ollama serve
#
# Test suites can rely on this same default port (11435) as a fixed,
# documented target rather than each picking their own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/llama-cpp-release.sh
source "$SCRIPT_DIR/lib/llama-cpp-release.sh"

LLAMA_CPP_REPO="zbrad/llama.cpp"
LIB_OLLAMA_DIR="$OLLAMA_ROOT/build/lib/ollama"
DEST_DIR="$LIB_OLLAMA_DIR/local_llama_cpp"
VARIANT=""
CUDA_VERSION=""
EXACT_TAG=""
PORT="11435"
DO_SERVE=false
DRY_RUN=false

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --variant)      VARIANT="$2";      shift 2 ;;
        --cuda-version) CUDA_VERSION="$2"; shift 2 ;;
        --tag)          EXACT_TAG="$2";    shift 2 ;;
        --port)         PORT="$2";         shift 2 ;;
        --serve)        DO_SERVE=true;     shift   ;;
        --dry-run)      DRY_RUN=true;      shift   ;;
        --help|-h)      usage ;;
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
echo "Deploy dir:   $DEST_DIR  (local, no sudo)"
echo "Port:         $PORT"
$DRY_RUN && echo "(dry run — no files written)"
echo

llama_release_fetch "$(mktemp -d)"
llama_release_copy_into "$LLAMA_CPP_SOURCE_DIR" "$DEST_DIR"

echo
echo "Activating llama-server..."
if $DRY_RUN; then
    echo "[dry-run] ln -sf $DEST_DIR/llama-server $LIB_OLLAMA_DIR/llama-server"
else
    mkdir -p "$LIB_OLLAMA_DIR"
    ln -sf "$DEST_DIR/llama-server" "$LIB_OLLAMA_DIR/llama-server"
    echo "  linked: $LIB_OLLAMA_DIR/llama-server -> $DEST_DIR/llama-server"
fi

echo
echo "Done ($TAG). No system files touched, no sudo used."
echo
echo "Start Ollama against this build:"
echo "  cd $OLLAMA_ROOT && OLLAMA_HOST=127.0.0.1:$PORT ./ollama serve"

if $DO_SERVE && ! $DRY_RUN; then
    echo
    echo "Launching (--serve): OLLAMA_HOST=127.0.0.1:$PORT ./ollama serve"
    cd "$OLLAMA_ROOT"
    exec env OLLAMA_HOST="127.0.0.1:$PORT" ./ollama serve
fi
