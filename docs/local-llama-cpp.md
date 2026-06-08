# Using a Local llama.cpp Build with Ollama

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
`cudaMemcpyAsync` per tensor from cold mmap pages. A local build with
`--no-mmap` wired in via the model Modelfile achieves 1131 MB/s on the same
hardware. Hardware-specific tuning like this often lives in a local fork
before (or instead of) landing upstream.

**Instrumentation and debugging.** When diagnosing load-time or inference
performance, adding `fprintf(stderr, ...)` markers to `llama-model-loader.cpp`
or `ggml-backend.cpp` is far faster than waiting for a release. A local build
lets you iterate on instrumentation freely without forking Ollama itself.

**Testing unreleased architecture support.** New model architectures land in
llama.cpp before Ollama picks them up. A local llama.cpp build lets Ollama
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

## Deploying a Local Build

The `scripts/deploy-local-llama-cpp.sh` script automates the deployment. It
expects the two projects to be siblings under a common parent directory:

```
$GIT_ROOT/
  ollama/       ← this repo
  llama.cpp/    ← your local llama.cpp build
```

Build your local llama.cpp, then run the script as root:

```bash
# Build llama.cpp (example for GB10 / DGX Spark)
cd $GIT_ROOT/llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=1210
cmake --build build --config Release -j$(nproc)

# Deploy into Ollama
cd $GIT_ROOT/ollama
sudo systemctl stop ollama
sudo ./scripts/deploy-local-llama-cpp.sh
sudo systemctl daemon-reload
sudo systemctl start ollama
```

The script copies everything from `$GIT_ROOT/llama.cpp/bin/` to
`/usr/local/lib/ollama/local_llama_cpp/` and symlinks
`/usr/local/lib/ollama/llama-server` to the deployed binary. Pass
`--dry-run` to preview what it will do without writing any files.

Override either path if your layout differs:

```bash
sudo ./scripts/deploy-local-llama-cpp.sh \
  --llama-cpp-source-dir /path/to/llama.cpp/bin \
  --ollama-target-dir /usr/local/lib/ollama/my_build
```

## Keeping In Sync

The deployed build is not updated automatically. After rebuilding your local
llama.cpp, re-run the deploy script and restart Ollama to pick up the changes.

When Ollama itself releases a new version, its installer will overwrite
`/usr/local/lib/ollama/llama-server`. Re-run the deploy script after an
Ollama upgrade to restore your local build.

## Reverting

The deploy script backs up the original binary before symlinking:

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
