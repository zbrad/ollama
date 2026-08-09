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
`v<build-number>-<variant>-cu<XXX>`, e.g. `v10333-gb10-cu133`. The
`scripts/fetch-llama-cpp-release.sh` script in this repo downloads the
release matching your machine's detected GPU and CUDA toolkit version, and
deploys it — **no local llama.cpp checkout or build required.**

```bash
sudo systemctl stop ollama
sudo ./scripts/fetch-llama-cpp-release.sh
sudo systemctl daemon-reload
sudo systemctl start ollama
```

The script:
1. Detects your GPU variant from `nvidia-smi` (gb10/rtx40/rtx50) and your
   CUDA toolkit version from `nvcc` (falling back to `nvidia-smi`'s reported
   max-supported version if `nvcc` isn't installed).
2. Finds the matching release on `zbrad/llama.cpp` — exact CUDA version
   match preferred; if none exists, falls back to the newest release with
   CUDA major version match and toolkit version ≤ this host's (CUDA's
   runtime ABI is forward-compatible only within a major series).
3. Downloads and extracts the release tarball, copies `llama-server` +
   `llama-quantize` + all shared libraries into
   `/usr/local/lib/ollama/local_llama_cpp/`, normalizes sonames, and
   symlinks `/usr/local/lib/ollama/llama-server` to the deployed binary.

Pass `--dry-run` to preview what it will do without writing any files.

Override any of the detected/default values:

```bash
sudo ./scripts/fetch-llama-cpp-release.sh \
  --variant gb10 \
  --cuda-version 13.3 \
  --tag v10333-gb10-cu133 \
  --ollama-target-dir /usr/local/lib/ollama/my_build
```

`--tag` fetches an exact release, bypassing variant/CUDA auto-detection and
matching entirely.

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
