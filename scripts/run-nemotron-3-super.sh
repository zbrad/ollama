#!/usr/bin/env bash
# Run nemotron-3-super against a tuned Ollama instance (system, ~/.local
# via install-tuned.sh, or a custom OLLAMA_HOST), using the model's own
# baked-in "best guidance" parameters — set once via the model's Modelfile
# params, not re-specified here:
#
#   min_p=0.01  num_ctx=262144  num_gpu=99  num_thread=8
#   temperature=0.6  top_p=0.95  use_mmap=false
#
# (See docs/spark/nemotron-super-spark.md in the llama.cpp repo for the
# rationale behind each of these — ctx-size, temp/top-p for reasoning ON,
# use_mmap=false for the 313s->72s DGX Spark load-time fix.) This script
# doesn't override them; it just finds the right instance to run against
# and confirms the model is actually there before handing off to `ollama
# run`, rather than a confusing "model not found" partway through.
#
# Usage:
#   ./scripts/run-nemotron-3-super.sh                  # interactive session
#   ./scripts/run-nemotron-3-super.sh "your prompt"     # one-shot, non-interactive
#
# Env overrides:
#   OLLAMA_HOST   which instance to use (default: probes 127.0.0.1:11434
#                 system, then 127.0.0.1:11435 tuned ~/.local, in that order)
#   OLLAMA_BIN    path to the ollama binary (default: first found among
#                 $HOME/.local/bin/ollama, ollama on PATH)
#   MODEL_NAME    default: nemotron-3-super

set -euo pipefail

MODEL_NAME="${MODEL_NAME:-nemotron-3-super}"

status() { echo ">>> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

# --- Find an ollama binary ---
if [ -n "${OLLAMA_BIN:-}" ]; then
    :
elif [ -x "$HOME/.local/bin/ollama" ]; then
    OLLAMA_BIN="$HOME/.local/bin/ollama"
elif command -v ollama >/dev/null 2>&1; then
    OLLAMA_BIN="$(command -v ollama)"
else
    die "no ollama binary found ($HOME/.local/bin/ollama or PATH) — run install-tuned.sh first"
fi
status "Using: $OLLAMA_BIN"

# --- Find a reachable instance, unless OLLAMA_HOST is already set ---
if [ -z "${OLLAMA_HOST:-}" ]; then
    for candidate in "127.0.0.1:11434" "127.0.0.1:11435"; do
        if curl -fsS --max-time 2 "http://${candidate}/api/version" >/dev/null 2>&1; then
            OLLAMA_HOST="$candidate"
            break
        fi
    done
    [ -n "${OLLAMA_HOST:-}" ] || die "no reachable Ollama instance found on 127.0.0.1:11434 or :11435 — start one first (sudo systemctl start ollama, or systemctl --user start ollama-tuned, or run 'ollama serve' directly), or set OLLAMA_HOST explicitly"
fi
export OLLAMA_HOST
status "Instance:   http://$OLLAMA_HOST"

# --- Confirm the model is actually present on this instance ---
if ! "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -q "^${MODEL_NAME}:"; then
    die "model '$MODEL_NAME' not found on this instance (checked: \`ollama list\` at $OLLAMA_HOST).
      Pull it:   $OLLAMA_BIN pull $MODEL_NAME
      Or copy an existing local copy from another machine's model store --
      see the nemotron-3-super scp/rsync guidance in project memory
      (tuned-builds-expansion-plan.md, -home-zbrad-gh) for the exact blob
      digests and destination layout."
fi
status "Model '$MODEL_NAME' confirmed present."

echo ""
if [ "$#" -gt 0 ]; then
    exec "$OLLAMA_BIN" run "$MODEL_NAME" "$@"
else
    exec "$OLLAMA_BIN" run "$MODEL_NAME"
fi
