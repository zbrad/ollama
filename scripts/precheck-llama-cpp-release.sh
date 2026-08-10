#!/usr/bin/env bash
# Validate a machine's environment before running
# install-llama-cpp-release.sh — checks everything that script assumes
# (GPU/driver/CUDA toolkit present, tools available, network reachable, a
# matching release actually exists) and reports pass/fail clearly, instead
# of letting the installer fail partway through a real download/deploy.
#
# Self-contained, same as install-llama-cpp-release.sh — works piped
# straight into bash, no checkout required:
#
#   curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/precheck-llama-cpp-release.sh | bash
#
# Does NOT download the release tarball itself (that's the actual install
# step) — only makes small GitHub API metadata calls to confirm a matching
# release exists, which is itself one of the things worth checking before
# committing to the real download.
#
# Exit code 0 = safe to run install-llama-cpp-release.sh. Non-zero = at
# least one check failed; see output for which and why.

set -uo pipefail  # deliberately not -e: we want every check to run and report, not stop at the first failure

LLAMA_CPP_REPO="zbrad/llama.cpp"
VARIANT="${LLAMA_CPP_VARIANT:-}"
CUDA_VERSION="${LLAMA_CPP_CUDA_VERSION:-}"

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; WARN=$((WARN+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "Tools"
for tool in curl tar bash; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "$tool found"
    else
        bad "$tool not found — required"
    fi
done
if command -v sudo >/dev/null 2>&1 || [ "$(id -u)" -eq 0 ]; then
    ok "sudo available (or already root) — needed to deploy into /usr/local/lib/ollama/"
else
    bad "not root and sudo not found — cannot deploy into /usr/local/lib/ollama/"
fi

section "Network"
if curl -fsSL --max-time 10 -o /dev/null "https://api.github.com" 2>/dev/null; then
    ok "api.github.com reachable"
else
    bad "api.github.com not reachable — check network/proxy/firewall"
fi
if curl -fsSL --max-time 10 -o /dev/null "https://raw.githubusercontent.com" 2>/dev/null; then
    ok "raw.githubusercontent.com reachable"
else
    bad "raw.githubusercontent.com not reachable — check network/proxy/firewall"
fi
if curl -fsSL --max-time 10 -o /dev/null "https://github.com" 2>/dev/null; then
    ok "github.com reachable (release asset downloads use this)"
else
    bad "github.com not reachable — check network/proxy/firewall"
fi

section "GPU"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    bad "nvidia-smi not found — no NVIDIA driver installed?"
    echo "      Driver download: https://www.nvidia.com/Download/index.aspx"
    echo "      DGX Spark setup guide: https://build.nvidia.com/spark/llama-cpp/overview"
else
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    if [ -z "$gpu_name" ]; then
        bad "nvidia-smi found but reported no GPU — driver installed but no GPU visible?"
        echo "      Driver troubleshooting: https://docs.nvidia.com/datacenter/tesla/tesla-installation-notes/index.html"
    else
        ok "GPU detected: $gpu_name"
        if [ -z "$VARIANT" ]; then
            case "$gpu_name" in
                *GB10*)   VARIANT="gb10" ;;
                *RTX*40*) VARIANT="rtx40" ;;
                *RTX*50*) VARIANT="rtx50" ;;
                *) bad "GPU '$gpu_name' doesn't match a known variant (gb10/rtx40/rtx50) — set LLAMA_CPP_VARIANT explicitly" ;;
            esac
        fi
        [ -n "$VARIANT" ] && ok "variant resolved: $VARIANT"

        driver_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
        [ -n "$driver_ver" ] && ok "driver version: $driver_ver"
    fi

    if [ -n "$VARIANT" ]; then
        # Each variant is only built for one CPU architecture -- gb10 is
        # DGX Spark (aarch64); rtx40/rtx50 are consumer desktop/laptop
        # parts (x86_64). A mismatch here means either LLAMA_CPP_VARIANT
        # was overridden wrong, or (once more variants exist) an unusual
        # ARM+discrete-GPU combination the release tarballs don't cover.
        machine_arch="$(uname -m)"
        case "$VARIANT" in
            gb10)          expected_arch="aarch64" ;;
            rtx40|rtx50)   expected_arch="x86_64" ;;
            *)             expected_arch="" ;;
        esac
        if [ -n "$expected_arch" ]; then
            if [ "$machine_arch" = "$expected_arch" ]; then
                ok "architecture matches: $machine_arch (expected $expected_arch for $VARIANT)"
            else
                bad "architecture mismatch: this machine is $machine_arch, but variant '$VARIANT' releases are built for $expected_arch — set LLAMA_CPP_VARIANT explicitly if auto-detection got this wrong"
            fi
        fi
    fi

    if [ -e /dev/nvidia0 ] || [ -e /dev/nvidiactl ]; then
        ok "NVIDIA device nodes present (/dev/nvidia*)"
    else
        warn "no /dev/nvidia* device nodes found — driver may not be fully loaded"
    fi
fi

section "CUDA Toolkit"
if command -v nvcc >/dev/null 2>&1; then
    nvcc_ver="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
    if [ -n "$nvcc_ver" ]; then
        ok "nvcc found, CUDA toolkit $nvcc_ver"
        [ -z "$CUDA_VERSION" ] && CUDA_VERSION="$nvcc_ver"
    else
        warn "nvcc found but version could not be parsed"
    fi
else
    warn "nvcc not found — will fall back to nvidia-smi's reported max-supported CUDA version (less precise; the installed toolkit could be older)"
    echo "      CUDA Toolkit download: https://developer.nvidia.com/cuda-downloads"
    if command -v nvidia-smi >/dev/null 2>&1; then
        smi_cuda="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}')"
        if [ -n "$smi_cuda" ]; then
            ok "nvidia-smi reports max-supported CUDA: $smi_cuda"
            [ -z "$CUDA_VERSION" ] && CUDA_VERSION="$smi_cuda"
        else
            bad "could not determine CUDA version from nvcc or nvidia-smi — set LLAMA_CPP_CUDA_VERSION explicitly"
        fi
    fi
fi
if [ -n "$CUDA_VERSION" ]; then
    cuda_major="${CUDA_VERSION%%.*}"
    found_cudart="$(ldconfig -p 2>/dev/null | grep -c "libcudart\.so\.${cuda_major}" || true)"
    if [ "$found_cudart" -gt 0 ]; then
        ok "libcudart.so.${cuda_major} resolvable via ldconfig"
    else
        bad "libcudart.so.${cuda_major} not found via ldconfig — CUDA toolkit runtime libs missing or not in ld cache (run ldconfig, or check /usr/local/cuda*/lib*)"
        echo "      CUDA Toolkit download: https://developer.nvidia.com/cuda-downloads"
        echo "      CUDA ${cuda_major}.x archive (if you need a specific version): https://developer.nvidia.com/cuda-toolkit-archive"
    fi
fi

section "Ollama"
if command -v ollama >/dev/null 2>&1; then
    ok "ollama binary found: $(command -v ollama)"
else
    bad "ollama not found — install it first: curl -fsSL https://ollama.com/install.sh | sh"
    echo "      Ollama downloads/docs: https://ollama.com/download"
fi
if command -v systemctl >/dev/null 2>&1; then
    # Captured to a variable before grepping, not `systemctl ... | grep -q`
    # directly -- grep -q exits after its first match, which can SIGPIPE a
    # still-writing systemctl (list-unit-files has 100+ lines) before it
    # finishes; under `pipefail` that reports as pipeline failure even
    # though grep found what it needed. Confirmed empirically: the direct
    # form spuriously warned "not registered" on a machine where the unit
    # plainly was (verified separately via the same command run standalone).
    unit_files="$(systemctl list-unit-files 2>/dev/null || true)"
    if echo "$unit_files" | grep -q '^ollama\.service'; then
        ok "ollama.service registered with systemd"
        state="$(systemctl is-active ollama 2>&1 || true)"
        ok "ollama.service current state: $state"
    else
        warn "ollama.service not registered with systemd — install/restart steps below assume it is"
    fi
else
    warn "systemctl not found — this environment may not use systemd; the install script's restart instructions won't apply as-is"
fi

section "Matching Release"
if [ -n "$VARIANT" ]; then
    candidates="$(
        curl -fsSL --max-time 15 "https://api.github.com/repos/${LLAMA_CPP_REPO}/releases?per_page=100" 2>/dev/null \
            | grep -o '"tag_name": *"[^"]*"' \
            | sed 's/.*"tag_name": *"\([^"]*\)"/\1/' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+\$" || true
    )"
    if [ -z "$candidates" ]; then
        bad "no releases found on $LLAMA_CPP_REPO matching variant '$VARIANT'"
    else
        count="$(echo "$candidates" | wc -l)"
        ok "$count release(s) found on $LLAMA_CPP_REPO for variant '$VARIANT'"
        if [ -n "$CUDA_VERSION" ]; then
            cuda_tag="cu${CUDA_VERSION//./}"
            if echo "$candidates" | grep -q -- "-${cuda_tag}\$"; then
                ok "exact CUDA match available: $(echo "$candidates" | grep -- "-${cuda_tag}\$" | sort -t- -k1.2 -n | tail -1)"
            else
                warn "no exact CUDA ${CUDA_VERSION} release for '$VARIANT' — installer will fall back across CUDA minor versions within the same major series (candidates: $(echo "$candidates" | tr '\n' ' '))"
            fi
        fi
    fi
else
    bad "no GPU variant resolved — cannot check for a matching release"
fi

section "Summary"
printf '  \033[32m%d passed\033[0m, \033[33m%d warning(s)\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Not safe to run install-llama-cpp-release.sh yet — fix the ✗ items above first."
    exit 1
else
    echo ""
    echo "All checks passed. Safe to run:"
    echo "  curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/install-llama-cpp-release.sh | sudo bash"
    exit 0
fi
