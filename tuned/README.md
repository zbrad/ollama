# tuned/ — tuned ollama binary

Builds the `ollama` Go binary from this fork (it carries the GPU-discovery fixes) for one GPU variant and one CUDA
toolkit, the same pair as the llama.cpp release it is released with. The layout and rules are `docs/ARCHITECTURE.md` in
[zbrad/tuned-common](https://github.com/zbrad/tuned-common). There is no Python in this build, so no build venv and
none of the Python dependency gates (setuptools, audit) apply.

```
CUDA_TAG=cu134 bash tuned/build.sh gb10        # Go binary                      -> tuned/build/cu134/bin/ollama
CUDA_TAG=cu134 bash tuned/full_test.sh gb10    # Go test suite                  -> .../releases/TEST_RESULTS_gb10.log
CUDA_TAG=cu134 bash tuned/package.sh gb10      # tarball + sha256 + DRAFT notes -> .../dist/
CUDA_TAG=cu134 bash tuned/smoke_test.sh gb10   # runs the tarball against its paired llama.cpp release
# review and commit tuned/releases/RELEASE_NOTES_<version>.md
CUDA_TAG=cu134 bash tuned/release.sh gb10      # gates only; writes the ready-marker, never publishes
CUDA_TAG=cu134 bash tuned/publish.sh gb10      # publishes exactly what release.sh saw
```

| File | Purpose |
|---|---|
| `env.sh` | device, toolkit and tree setup; sourced by every script |
| `repo.env` | ollama-only settings (the upstream ref `upstream/main` for the build-info stamp and notes) |
| `common.sh`, `sync-common.sh`, `common-data/` | vendored from tuned-common; refresh with `bash tuned/sync-common.sh sync` |
| `build.sh`, `full_test.sh`, `package.sh`, `smoke_test.sh`, `release.sh`, `publish.sh` | the stages above |
| `compliance.conf` | attestations for the checks `tools/tuned_compliance.sh` cannot make mechanically |

## Identity

- The release label is allocated in `build.sh` and baked into the binary (`ollama --version` prints it): the UTC date of
  `HEAD`'s commit plus the lowest sequence not yet taken by a tag (`GPU_TUNED_LABEL_SEQ=<n>` chooses it offline). The tag
  is `v0.<date>.<seq>-<variant>-<cuda>`. `release-label` and `build-commit` are written next to the binary.
- The tarball holds the Go binary and `BUILD_INFO.json` only. Ollama's own CMake-built native payload is deliberately not
  shipped: the zbrad/llama.cpp release it is paired with provides `llama-server` and its libraries.
- The pairing is chosen once, in `package.sh`: the newest llama.cpp release for this variant and toolkit, or the tag in
  `OLLAMA_TUNED_LLAMA_CPP_TAG`. It is recorded in `package-info.txt` (`llama_cpp_tag=`), the binary's build info and the
  notes; `smoke_test.sh` runs against exactly that release and `release.sh` checks it still exists.
- The binary goes to `tuned/build/<cuda-tag>/bin/`, never the repo-root `./ollama`. `tuned/build/` is gitignored.
