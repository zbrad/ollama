#!/usr/bin/env bash
# All-inclusive install of this fork's tuned Ollama + llama.cpp, from a
# fresh machine, no git clone required:
#
#   curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/install-tuned.sh | bash
#
# Default target is ~/.local — no sudo, no system files touched, runs on
# an alternate port (11435) so it never conflicts with any existing
# system-installed Ollama. Deploys two releases:
#   - zbrad/ollama's own tuned/package.sh release (the Go binary, carrying
#     this fork's GPU-discovery fixes on top of upstream — the official
#     ollama.com/install.sh binary does NOT have these and will segfault
#     against the llama.cpp release below; see docs/llama-cpp-release.md).
#   - zbrad/llama.cpp's tuned/package.sh release (llama-server + matched
#     native libs, GPU-enabled).
#
# Self-contained — doesn't source anything else, works piped straight into
# bash. Prefer this script for a fresh machine; deploy-llama-cpp-system.sh
# is still available separately for deploying just the llama.cpp piece
# into an existing system Ollama install.
#
# Env overrides:
#   INSTALL_DIR              default: $HOME/.local
#   OLLAMA_TUNED_PORT         default: 11435
#   LLAMA_CPP_VARIANT/LLAMA_CPP_CUDA_VERSION/LLAMA_CPP_TAG  (GPU release matching)
#   OLLAMA_TAG                pin an exact ollama release tag (default: latest for this arch)
#   SKIP_STOP_SYSTEM_PROMPT   set to skip the "stop the system service?" prompt entirely

set -euo pipefail

OLLAMA_REPO="zbrad/ollama"
LLAMA_CPP_REPO="zbrad/llama.cpp"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local}"
PORT="${OLLAMA_TUNED_PORT:-11435}"
VARIANT="${LLAMA_CPP_VARIANT:-}"
CUDA_VERSION="${LLAMA_CPP_CUDA_VERSION:-}"
EXACT_TAG="${LLAMA_CPP_TAG:-}"
OLLAMA_TAG="${OLLAMA_TAG:-}"

status() { echo ">>> $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required but not found"
command -v tar >/dev/null 2>&1 || die "tar is required but not found"
command -v go >/dev/null 2>&1 || true  # not required at runtime, only noted if relevant later

GOARCH="$(uname -m)"
case "$GOARCH" in
    aarch64|arm64) GOARCH="arm64" ;;
    x86_64|amd64)  GOARCH="amd64" ;;
    *) die "unsupported architecture: $GOARCH" ;;
esac

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

status "Install dir:  $INSTALL_DIR (no sudo)"
status "Port:         $PORT"
status "Variant:      $VARIANT"
status "CUDA version: $CUDA_VERSION ($CUDA_TAG)"
status "Go arch:      $GOARCH"

# --- Optionally offer to stop a running system Ollama service ---
# Not a hard requirement (this install targets an alternate port, so it
# doesn't actually conflict) -- offered because running two GPU-capable
# instances at once contends for the same VRAM. Only prompts on a real
# TTY; never prompts (or acts) when piped non-interactively.
if [ -z "${SKIP_STOP_SYSTEM_PROMPT:-}" ] && command -v systemctl >/dev/null 2>&1; then
    sys_state="$(systemctl is-active ollama 2>&1 || true)"
    if [ "$sys_state" = "active" ] || [ "$sys_state" = "activating" ]; then
        status "A system Ollama service is currently $sys_state (port 11434)."
        if [ -t 0 ] && [ -t 1 ]; then
            read -r -p ">>> Stop it now to free GPU memory for this install? [y/N] " reply
            case "$reply" in
                [yY]|[yY][eE][sS])
                    status "Stopping system ollama.service..."
                    sudo systemctl stop ollama || status "  (failed to stop it — continuing anyway)"
                    ;;
                *) status "Leaving system service running." ;;
            esac
        else
            status "Non-interactive session — leaving it running. Set SKIP_STOP_SYSTEM_PROMPT=1 to silence this notice, or stop it yourself: sudo systemctl stop ollama"
        fi
    fi
fi

# --- Resolve llama.cpp release tag ---
if [ -z "$EXACT_TAG" ]; then
    candidates="$(
        curl -fsSL "https://api.github.com/repos/${LLAMA_CPP_REPO}/releases?per_page=100" \
            | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/.*"tag_name": *"\([^"]*\)"/\1/' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+\$" || true
    )"
    [ -n "$candidates" ] || die "no llama.cpp releases found on $LLAMA_CPP_REPO matching variant '$VARIANT'"

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
    [ -n "$TAG" ] || die "no llama.cpp release found matching variant '$VARIANT' and CUDA major ${CUDA_MAJOR}.x"
else
    TAG="$EXACT_TAG"
fi
status "llama.cpp release: $TAG"

# --- Resolve ollama binary release tag ---
if [ -z "$OLLAMA_TAG" ]; then
    OLLAMA_TAG="$(
        curl -fsSL "https://api.github.com/repos/${OLLAMA_REPO}/releases?per_page=100" \
            | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/.*"tag_name": *"\([^"]*\)"/\1/' \
            | grep -E "^v[0-9]+-${GOARCH}\$" \
            | sort -t- -k1.2 -n | tail -1 || true
    )"
    [ -n "$OLLAMA_TAG" ] || die "no ollama releases found on $OLLAMA_REPO matching arch '$GOARCH'"
fi
status "ollama release:     $OLLAMA_TAG"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Fetch + install the ollama binary ---
ollama_asset_name="$(
    curl -fsSL "https://api.github.com/repos/${OLLAMA_REPO}/releases/tags/${OLLAMA_TAG}" \
        | grep -o '"name": *"[^"]*\.tar\.gz"' | sed 's/.*"name": *"\([^"]*\)"/\1/' | head -1 || true
)"
[ -n "$ollama_asset_name" ] || die "no .tar.gz asset found in ollama release $OLLAMA_TAG"
status "Downloading ollama binary ($ollama_asset_name)..."
curl -fsSL "https://github.com/${OLLAMA_REPO}/releases/download/${OLLAMA_TAG}/${ollama_asset_name}" -o "$WORK_DIR/ollama.tar.gz"
mkdir -p "$WORK_DIR/ollama-extracted"
tar -xzf "$WORK_DIR/ollama.tar.gz" -C "$WORK_DIR/ollama-extracted"
[ -x "$WORK_DIR/ollama-extracted/ollama" ] || die "ollama binary not found after extracting $OLLAMA_TAG"

mkdir -p "$INSTALL_DIR/bin"
cp -p "$WORK_DIR/ollama-extracted/ollama" "$INSTALL_DIR/bin/ollama"
status "Installed: $INSTALL_DIR/bin/ollama"

# --- Fetch + deploy the llama.cpp release ---
llama_asset_name="$(
    curl -fsSL "https://api.github.com/repos/${LLAMA_CPP_REPO}/releases/tags/${TAG}" \
        | grep -o '"name": *"[^"]*\.tar\.gz"' | sed 's/.*"name": *"\([^"]*\)"/\1/' | head -1 || true
)"
[ -n "$llama_asset_name" ] || die "no .tar.gz asset found in llama.cpp release $TAG"
status "Downloading llama.cpp release ($llama_asset_name)..."
curl -fsSL "https://github.com/${LLAMA_CPP_REPO}/releases/download/${TAG}/${llama_asset_name}" -o "$WORK_DIR/llama.tar.gz"

LIB_OLLAMA_DIR="$INSTALL_DIR/lib/ollama"
TARGET_DIR="$LIB_OLLAMA_DIR/local_llama_cpp"
mkdir -p "$TARGET_DIR"
tar -xzf "$WORK_DIR/llama.tar.gz" -C "$TARGET_DIR"
[ -x "$TARGET_DIR/llama-server" ] || die "llama-server not found after extracting $TAG"

status "Normalizing sonames..."
for lib in "$TARGET_DIR"/lib*.so.*; do
    [ -f "$lib" ] || continue
    lib_name="$(basename "$lib")"
    case "$lib_name" in
        *.[0-9]*.[0-9]*.[0-9]*)
            normalized="$(echo "$lib_name" | sed -E 's/\.[0-9]+\.[0-9]+\.[0-9]+$/.0.0.0/')"
            [ "$normalized" != "$lib_name" ] && cp -p "$lib" "$TARGET_DIR/$normalized"
            ;;
    esac
done

ln -sf "$TARGET_DIR/llama-server" "$LIB_OLLAMA_DIR/llama-server"
status "Deployed: $LIB_OLLAMA_DIR (local_llama_cpp/ + llama-server symlink)"

# --- Optional: systemd --user unit, if a user session is available ---
UNIT_INSTALLED=false
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/ollama-tuned.service" <<EOF
[Unit]
Description=Ollama (tuned, ${INSTALL_DIR})

[Service]
Environment="OLLAMA_HOST=127.0.0.1:${PORT}"
ExecStart=${INSTALL_DIR}/bin/ollama serve
Restart=on-failure

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    UNIT_INSTALLED=true
    status "Installed systemd --user unit: ollama-tuned.service"
fi

echo ""
status "Done ($TAG + $OLLAMA_TAG)."
echo ""
if $UNIT_INSTALLED; then
    echo "Start it:"
    echo "  systemctl --user enable --now ollama-tuned"
    echo "  systemctl --user status ollama-tuned"
    echo ""
    echo "Or run it directly in the foreground:"
fi
echo "  OLLAMA_HOST=127.0.0.1:${PORT} ${INSTALL_DIR}/bin/ollama serve"
echo ""
echo "Then, in another shell:"
echo "  OLLAMA_HOST=127.0.0.1:${PORT} ${INSTALL_DIR}/bin/ollama run <model>"
