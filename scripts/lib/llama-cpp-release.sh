#!/usr/bin/env bash
# scripts/lib/llama-cpp-release.sh — shared functions for resolving and
# fetching a zbrad/llama.cpp tuned-builds release. Sourced by
# deploy-llama-cpp-local.sh and deploy-llama-cpp-system.sh; not executed
# directly.
#
# Exposes:
#   llama_release_detect_variant       — sets VARIANT from nvidia-smi
#   llama_release_detect_cuda          — sets CUDA_VERSION/CUDA_TAG/CUDA_MAJOR
#   llama_release_resolve_tag          — sets TAG (see matching rules below)
#   llama_release_fetch <dest-dir>     — downloads+extracts TAG's tarball into dest-dir
#
# Expects LLAMA_CPP_REPO, VARIANT, CUDA_VERSION, EXACT_TAG, DRY_RUN to
# already be set by the caller (empty string is fine for auto-detect).

llama_release_die() { echo "error: $*" >&2; exit 1; }

llama_release_detect_variant() {
    [[ -n "$VARIANT" ]] && return 0
    local gpu_name
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
    case "$gpu_name" in
        *GB10*)    VARIANT="gb10" ;;
        *RTX*40*)  VARIANT="rtx40" ;;
        *RTX*50*)  VARIANT="rtx50" ;;
        *) llama_release_die "could not auto-detect GPU variant from nvidia-smi output ('$gpu_name'); pass --variant explicitly" ;;
    esac
}

llama_release_detect_cuda() {
    if [[ -z "$CUDA_VERSION" ]]; then
        if command -v nvcc >/dev/null 2>&1; then
            CUDA_VERSION="$(nvcc --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')"
        fi
        if [[ -z "$CUDA_VERSION" ]]; then
            CUDA_VERSION="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9]+\.[0-9]+' | awk '{print $3}')"
        fi
        [[ -n "$CUDA_VERSION" ]] || llama_release_die "could not auto-detect CUDA version (nvcc/nvidia-smi both failed); pass --cuda-version explicitly"
    fi
    CUDA_TAG="cu${CUDA_VERSION//./}"
    CUDA_MAJOR="${CUDA_VERSION%%.*}"
}

# llama_release_resolve_tag — sets TAG. Exact CUDA match preferred (highest
# build number wins); falls back to the newest release with matching CUDA
# major and toolkit minor <= this host's (CUDA's runtime ABI is
# forward-compatible only within a major series).
llama_release_resolve_tag() {
    if [[ -n "$EXACT_TAG" ]]; then
        TAG="$EXACT_TAG"
        return 0
    fi

    mapfile -t candidates < <(
        gh release list --repo "$LLAMA_CPP_REPO" --limit 200 2>/dev/null \
            | awk -F'\t' '{print $3}' \
            | grep -E "^v[0-9]+-${VARIANT}-cu[0-9]+$" || true
    )
    [[ "${#candidates[@]}" -gt 0 ]] || llama_release_die "no releases found on $LLAMA_CPP_REPO matching variant '$VARIANT' (tag pattern v<N>-${VARIANT}-cu<XXX>)"

    TAG="$(
        for t in "${candidates[@]}"; do
            [[ "$t" == *"-${CUDA_TAG}" ]] && echo "$t"
        done | sort -t- -k1.2 -n | tail -1
    )"

    if [[ -z "$TAG" ]]; then
        TAG="$(
            for t in "${candidates[@]}"; do
                t_cuda_tag="${t##*-cu}"
                t_major="${t_cuda_tag:0:2}"
                t_minor="${t_cuda_tag:2}"
                [[ "$t_major" == "$CUDA_MAJOR" ]] || continue
                host_minor="${CUDA_VERSION#*.}"
                if (( 10#$t_minor <= 10#$host_minor )); then
                    echo "$t"
                fi
            done | sort -t- -k1.2 -n | tail -1
        )"
        [[ -n "$TAG" ]] && echo "NOTE: no exact CUDA ${CUDA_VERSION} release for ${VARIANT}; falling back to $TAG (CUDA runtime ABI is forward-compatible within a major series)." >&2
    fi

    [[ -n "$TAG" ]] || llama_release_die "no release found on $LLAMA_CPP_REPO matching variant '$VARIANT' and CUDA major ${CUDA_MAJOR}.x (candidates: ${candidates[*]})"
}

# llama_release_fetch <dest-dir> — downloads and extracts TAG's tarball
# into dest-dir (created if needed). Sets LLAMA_CPP_SOURCE_DIR=<dest-dir>.
# Honors DRY_RUN (leaves dest-dir empty, just prints what would happen).
llama_release_fetch() {
    local dest_dir="$1"
    mkdir -p "$dest_dir"
    LLAMA_CPP_SOURCE_DIR="$dest_dir"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo "[dry-run] gh release download $TAG --repo $LLAMA_CPP_REPO"
        echo "[dry-run] tar -xzf <asset> -C $dest_dir"
        return 0
    fi

    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "$work_dir"' RETURN

    gh release download "$TAG" --repo "$LLAMA_CPP_REPO" --dir "$work_dir" --clobber
    local asset
    asset="$(find "$work_dir" -maxdepth 1 -name '*.tar.gz' | head -1)"
    [[ -n "$asset" ]] || llama_release_die "no .tar.gz asset found in release $TAG"
    tar -xzf "$asset" -C "$dest_dir"

    [[ -x "$dest_dir/llama-server" ]] || llama_release_die "llama-server not found after extracting $TAG"
}

# llama_release_copy_into <source-dir> <dest-dir> — copies binaries +
# shared libraries from source-dir into dest-dir, normalizing X.Y.Z
# sonames to 0.0.0 (matching Ollama's ExternalProject convention). Used
# identically by both local and system deploy modes; only the
# destination (and whether it needs root) differs.
llama_release_copy_into() {
    local source_dir="$1" dest_dir="$2"

    if [[ "${DRY_RUN:-false}" == true ]]; then
        echo "[dry-run] mkdir -p $dest_dir"
        echo "[dry-run] copy llama-server, llama-quantize, lib*.so.* from $source_dir -> $dest_dir"
        return 0
    fi

    mkdir -p "$dest_dir"

    echo "Copying binaries..."
    for bin in llama-server llama-quantize; do
        if [[ -f "$source_dir/$bin" ]]; then
            cp -p "$source_dir/$bin" "$dest_dir/"
            echo "  copied: $bin"
        fi
    done

    echo "Copying shared libraries..."
    for lib in "$source_dir"/lib*.so.*; do
        [[ -f "$lib" ]] || continue
        local lib_name
        lib_name="$(basename "$lib")"
        cp -p "$lib" "$dest_dir/"
        echo "  copied: $lib_name"

        if [[ "$lib_name" =~ \.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local normalized
            normalized="$(echo "$lib_name" | sed 's/\.[0-9]*\.[0-9]*\.[0-9]*$/.0.0.0/')"
            if [[ "$normalized" != "$lib_name" ]]; then
                cp -p "$dest_dir/$lib_name" "$dest_dir/$normalized"
                echo "  normalized: $lib_name -> $normalized"
            fi
        fi
    done
}
