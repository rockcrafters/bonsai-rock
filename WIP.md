# WIP -- bonsai-1.7B-rock

internal progress tracker + handoff notes. user-facing docs live in `README.md`.

last touched: 2026-07-23.

## repo layout (restructured 2026-07-23, mirrors not-quite-rust-rock)

- go app at repo root under `go/` (module `bonsai-rock`, unchanged import paths)
- per-version rock dir `bonsai/1.7/`: `rockcraft.yaml`, `makefile`, `spread.yaml`,
  `hack/*`, `tests/spread/*`
- `hack/` scripts: `build.sh` (local full pipeline), `inject.sh` (pack-agnostic
  inject half, reused by CI), `inject-layers.sh` (oci surgery, unchanged),
  `download-model.sh` (hf -> `.cache/`), `hash_inputs.sh`, spread allocate/discard
- CI in `.github/workflows/`: `build.yaml` (per-arch pack via craft-actions +
  fetch-model + inject, buildah multiarch) + `test.yaml` (spread on sshd-adhoc),
  driven by `ci.yaml` (PR/push, no publish) and `release.yaml` (tag `r*` -> ghcr).
  `REVISION` = r0 (unreleased).

## goal

a bare-base canonical rock running bonsai-1.7B on cpu, with two pebble services
(model evaluator + htmx chat frontend). model weights ship as 4 separate oci
layers (parallel download) injected below the app content layer via manifest
surgery, since rockcraft can't place files into chosen layers.

## decisions locked

- **language**: go for both services (evaluator = go+cgo, frontend = pure go).
  considered C for the evaluator, rejected -- llama.cpp is C++ so `libstdc++` is
  required regardless of wrapper language; C would only add http/json pain.
- **linking**: dynamic. `libllama.so`/`libggml*.so` bundled in the app layer.
  (static llama.cpp is the alternative if we ever want to drop the bundled libs.)
- **model delivery**: split into 4 chunks, one oci layer each, at
  `/usr/share/bonsai/<model>.part0[0-3]`, injected *below* the app content layer.
  evaluator `cat`s them into `/var/lib/bonsai/model.gguf` on startup.
- **entrypoint**: pebble (idiomatic rock), two services `evaluator` + `frontend`.

## resolved unknowns

- **quant**: filename says `Q1_0` but that's prism-ml's label -- internally it's
  ggml type 41 / file_type 40, qwen3 arch, gguf v3. 1-bit g128 (1.125 bpw).
- **llama.cpp**: **mainline loads it** -- `bonsai.py` runs the same Q1_0 gguf through
  stock `llama-cpp-python` (a plain mainline build) and works. so the PrismML fork the
  design first assumed is NOT needed; rock builds mainline `github.com/ggml-org/llama.cpp`.
  (earlier "mainline cannot load it" note was wrong / predated a mainline that can.)
  TODO: pin `source-tag` to the exact llama.cpp tag that the known-good
  `llama-cpp-python` vendors (currently placeholder `bNNNN`).
- **C API**: the cgo wrapper already targets current mainline (vocab-based tokenize,
  `llama_memory_clear`/`llama_get_memory`, `llama_model_chat_template`) -- no change.

## done + validated (on macos dev box)

- [x] repo scaffold: `go/cmd/{frontend,evaluator}`, `go/internal/llama`, `bonsai/1.7/{hack,tests}`, rockcraft.yaml
- [x] frontend: serves page + vendored htmx + `POST /send` proxy (no runtime CDN)
- [x] evaluator: http server, startup 4-chunk reassembly, qwen3 `<think>` strip
- [x] cgo llama wrapper: load, chat-template, tokenize, greedy/temp sampler, decode loop
- [x] **real inference on mac**: loaded Q1_0, coherent output (both the cgo evaluator
      and `bonsai.py` via stock mainline `llama-cpp-python`)
- [x] **full stack**: frontend htmx -> evaluator -> reply, rendered fragment
- [x] chunk reassembly byte-exact (sha matches original 248,302,272-byte gguf)
- [x] `inject-layers.sh` on a synthetic oci layout: blob integrity, index->manifest->
      config chain, 5-layer ordering (4 chunks below app), digest/diff_id consistency,
      byte-exact reassembly of injected chunks
- [x] `go vet` clean (stub + cgo tags), `GOOS=linux` cross-build ok
- [x] rockcraft.yaml builds mainline llama.cpp (fork dropped; `source-tag` needs pinning)

## todo (needs a network-capable linux box w/ rockcraft -- CI now covers most)

- [ ] **pin `source-tag`** in rockcraft.yaml (placeholder `bNNNN`) to the llama.cpp
      tag that the known-good `llama-cpp-python` vendors -- CI pack fails to fetch until then
- [ ] `hack/build.sh` end-to-end: fetch-model -> `rockcraft pack` -> inject -> repack
- [ ] **rockcraft go plugin + `source: ../../go`**: confirm a relative `..` source
      resolves (go moved to repo-root `go/`); confirm the plugin emits to `bin/`
      (the `organize:` map assumes it)
- [ ] confirm mainline llama.cpp builds inside rockcraft's ubuntu build env (cmake part
      installs `libllama.so` + `libggml*.so` + headers to the stage; prime globs assume that)
- [ ] **bare-base loader**: ELF interp `/lib64/ld-linux-x86-64.so.2` must resolve;
      bare skips usrmerge. likely need a `/lib64` symlink + `libstdc++`/`libgomp` staged
- [ ] skopeo validating the hand-edited manifest (prior lxc had no egress, couldn't test)
- [ ] actually run the rock (docker/podman), bind :8080, chat -- now the `test_boot` +
      `test_chat` spread tests (CI runs them per-arch on native runners)

## how to resume the local inference test

quickest sanity check that mainline loads the quant: `./bonsai.py "say hi in one word"`
(stock `llama-cpp-python`, no fork). for the cgo evaluator, build mainline llama.cpp
shared libs and point cgo at them:

```
L=/tmp/ai/llama.cpp   # git clone --depth 1 https://github.com/ggml-org/llama.cpp $L
                      # cmake -B $L/build -DBUILD_SHARED_LIBS=ON -DGGML_NATIVE=OFF $L
                      # cmake --build $L/build -j
cd go   # module root moved here
CGO_ENABLED=1 CGO_CFLAGS="-I$L/include -I$L/ggml/include" CGO_LDFLAGS="-L$L/build/bin" \
  go build -o /tmp/ai/ev-real ./cmd/evaluator
DYLD_LIBRARY_PATH="$L/build/bin" \
  BONSAI_MODEL_DIR=<dir with 4 .part files> BONSAI_MODEL=/tmp/out.gguf \
  /tmp/ai/ev-real
curl -s -X POST 127.0.0.1:8081/complete -d '{"prompt":"hi"}'
```

## gotchas / notes

- `umoci` can't insert layers *below* -- only appends on top. hence direct
  oci-layout surgery in `inject-layers.sh` (jq + tar + sha256). `rockcraft.skopeo`
  only does the transport conversion.
- "parallel download" win is from the 4-way split, not layer position (blobs are
  content-addressed). we inject below-content for clean separation anyway.
- the 237M gguf lives in `.cache/` (auto-downloaded from hf by `download-model.sh`);
  a copy at the repo root is reused if present. both gitignored.
- reassembly costs ~237M in the writable layer at startup (cached across restarts).
