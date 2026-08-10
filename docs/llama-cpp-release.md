# Using a Released llama.cpp Build with Ollama

Ollama bundles a specific version of llama.cpp and ships it as part of each
release. In most cases this is what you want. There are situations, however,
where you need to run Ollama against a different build of llama.cpp — one
that contains fixes, features, or compatibility code that has not yet been
merged upstream or released.

## When This Is Useful

**Model format compatibility.** Ollama stores some models using a non-standard
GGUF tensor layout (e.g. renamed tensors, injected hyperparameters). If you
want to load those blobs with a standalone `llama-server`, or if upstream
llama.cpp does not yet know how to handle a particular Ollama-format model,
you need a compatibility shim compiled into the llama.cpp build. An example
is `nemotron-3-super`, which requires a shim that renames `ffn_latent_in/out`
tensors and injects `moe_latent_size=1024` before the model loader runs.
See `docs/ollama-compat.md` in the llama.cpp repo for the full description.

**Performance fixes for specific hardware.** llama.cpp's generic code paths
are not always optimal for every device. On NVIDIA GB10 (DGX Spark), the
default mmap load path produces ~259 MB/s because it issues a synchronous
`cudaMemcpyAsync` per tensor from cold mmap pages. A tuned build with
`--no-mmap` wired in via the model Modelfile achieves 1131 MB/s on the same
hardware. Hardware-specific tuning like this often lives in a fork before
(or instead of) landing upstream.

**Testing unreleased architecture support.** New model architectures land in
llama.cpp before Ollama picks them up. A tuned llama.cpp build lets Ollama
serve models that its bundled version does not yet understand.

## How Ollama Finds llama-server

Ollama runs `llama-server` as a subprocess. At startup it searches for the
binary using `FindLlamaServer()`, which checks the following locations in
order on Linux:

1. `/usr/local/lib/ollama/llama-server` (standard installed path)
2. `<ollama-exe-dir>/../lib/ollama/llama-server`
3. `build/llama-server-*/bin/llama-server` (development layout)

GPU backend libraries (e.g. `libggml-cuda.so`) are discovered separately by
globbing `/usr/local/lib/ollama/*/ggml-*`. Each subdirectory that contains a
`ggml-*` library becomes a candidate GPU backend; Ollama sets `LD_LIBRARY_PATH`
and `GGML_BACKEND_PATH` accordingly when launching the server.

Replacing the binary at `/usr/local/lib/ollama/llama-server` is therefore
sufficient to make Ollama use a different llama.cpp build. The GPU backend
libraries in the subdirectory continue to be used unless you also replace them.

## Deploying a Published Release

`zbrad/llama.cpp`'s `tuned/package.sh` publishes a GitHub release for each
GPU-variant build (see that repo's `tuned/` directory) — tagged
`v<build-number>-<variant>-cu<XXX>`, e.g. `v10333-gb10-cu133`. Both repos are
public, so the release assets are fetchable from any machine, no auth or
`gh` CLI required.

### One-liner install on a fresh machine (no clone required)

```bash
curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/install-llama-cpp-release.sh | bash
```

Self-contained — `scripts/install-llama-cpp-release.sh` doesn't source
anything else, so it works piped straight into `bash` without a checkout of
this repo. Detects GPU variant + CUDA version the same way as the scripts
below, fetches the matching release via plain `curl` against the public
GitHub API (no `gh` CLI dependency), and deploys into
`/usr/local/lib/ollama/`. Auto-elevates via `sudo` if not already root.
Override detection with `LLAMA_CPP_VARIANT`, `LLAMA_CPP_CUDA_VERSION`, or
pin an exact release with `LLAMA_CPP_TAG`:

```bash
curl -fsSL https://raw.githubusercontent.com/zbrad/ollama/tuned-builds/scripts/install-llama-cpp-release.sh \
  | LLAMA_CPP_TAG=v10333-gb10-cu133 bash
```

Restart Ollama afterward: `sudo systemctl restart ollama`.

### From a checkout of this repo

Two scripts share common logic from `scripts/lib/llama-cpp-release.sh` (kept
in sync with the one-liner installer above, but only usable from a real
checkout since they `source` a sibling file by relative path):

- **`scripts/deploy-llama-cpp-system.sh`** — deploys into a system Ollama
  installation (`/usr/local/lib/ollama/`, managed by systemd). Needs `sudo`.
- **`scripts/deploy-llama-cpp-local.sh`** — deploys into this repo's own
  `build/lib/ollama/` dev-layout directory. No `sudo`, no system files
  touched. Runs Ollama on an alternate port (default `11435`) so it can run
  alongside a system Ollama instance. Useful for testing, and as a fixed,
  documented target for integration tests.

Both auto-detect your GPU variant (via `nvidia-smi`) and CUDA toolkit
version (via `nvcc`, falling back to `nvidia-smi`'s reported max-supported
version), find the matching release on `zbrad/llama.cpp` (exact CUDA match
preferred; falls back to the newest release with matching CUDA major and
toolkit version ≤ this host's — CUDA's runtime ABI is forward-compatible
only within a major series), download and extract it, copy
`llama-server` + `llama-quantize` + shared libraries into place, and
normalize sonames. **No local llama.cpp checkout or build required.**

### System mode

```bash
sudo systemctl stop ollama
sudo ./scripts/deploy-llama-cpp-system.sh
sudo systemctl daemon-reload
sudo systemctl start ollama
```

### Local mode

```bash
./scripts/deploy-llama-cpp-local.sh --serve
# or, to deploy without launching:
./scripts/deploy-llama-cpp-local.sh
cd .. && OLLAMA_HOST=127.0.0.1:11435 ./ollama serve
```

> **Fixed (2026-08-10)**: local mode's GPU-discovery subprocess used to
> segfault (Ollama's own common `libggml` at `build/lib/ollama/` loading
> ahead of the deployed tuned build's matching set, due to `llamaDir` being
> derived from an unresolved symlink path). Fixed in `llm/llama_server.go`
> by resolving symlinks before deriving `llamaDir`. Verified end-to-end
> with real inference (`./ollama run ...`), not just discovery logs — see
> the `-home-zbrad-gh` project memory's `tuned-builds-expansion-plan.md`
> for the full root-cause writeup.

Both scripts accept `--dry-run` (preview without writing files), `--variant`,
`--cuda-version`, and `--tag` (fetch an exact release, bypassing
auto-detection) overrides:

```bash
sudo ./scripts/deploy-llama-cpp-system.sh \
  --variant gb10 \
  --cuda-version 13.3 \
  --tag v10333-gb10-cu133 \
  --ollama-target-dir /usr/local/lib/ollama/my_build

./scripts/deploy-llama-cpp-local.sh --tag v10333-gb10-cu133 --port 11436
```

## Keeping In Sync

The deployed build is not updated automatically. After a new release is
published on `zbrad/llama.cpp`, re-run the fetch script and restart Ollama
to pick up the change — it always resolves to the latest matching release
at run time.

When Ollama itself releases a new version, its installer will overwrite
`/usr/local/lib/ollama/llama-server`. Re-run the fetch script after an
Ollama upgrade to restore the tuned build.

## Reverting

The fetch script backs up the original binary before symlinking:

```
/usr/local/lib/ollama/llama-server.bak
```

To revert to the Ollama-bundled binary:

```bash
sudo systemctl stop ollama
sudo cp /usr/local/lib/ollama/llama-server.bak /usr/local/lib/ollama/llama-server
sudo systemctl daemon-reload
sudo systemctl start ollama
```
