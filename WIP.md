# WIP -- bonsai-1.7B-rock

internal progress tracker + handoff notes. user-facing docs live in `README.md`.

last touched: 2026-07-23.

## repo layout (restructured 2026-07-23, mirrors not-quite-rust-rock)

- per-version rock dir `bonsai/1.7/` is self-contained: go module `bonsai-rock`
  (`cmd/`, `internal/`, `go.mod`), `rockcraft.yaml` (`source: .`), `makefile`,
  `spread.yaml`, `hack/*`, `tests/spread/*`. go must live here, not at repo root:
  rockcraft only mounts the project subtree, so a parent-dir source is unreachable
  (rockcraft#189).
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
  pinned to mainline release `b10092`.
- **C API**: the cgo wrapper already targets current mainline (vocab-based tokenize,
  `llama_memory_clear`/`llama_get_memory`, `llama_model_chat_template`) -- no change.

## done + validated (on macos dev box)

- [x] repo scaffold: `bonsai/1.7/{cmd/{frontend,evaluator},internal/llama,hack,tests}`, rockcraft.yaml
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
- [x] go source local to the version dir (`source: .`) -- fixes rockcraft#189 parent-source;
      **confirmed pulling in-rock**
- [x] go compiler: `go.mod` wants 1.26 -> build-snap `go/latest/stable` (1.26.x) +
      `GOTOOLCHAIN=local`, else the plugin trips go's toolchain auto-download
- [x] llama.cpp `b10092` cmake: disable ALL optional builds, esp `LLAMA_BUILD_TOOLS=OFF`
      (+ APP/UI) -- else the server/cli impl libs fail to link. only libllama+libggml wanted.
- [x] **llama.cpp `b10092` builds + stages in-rock** (confirmed -- "Staging llama" reached)
- [x] cgo link vs mainline lib split: add `-lggml-cpu` (holds `ggml_backend_cpu_reg`,
      referenced by libggml.so); `CMAKE_INSTALL_LIBDIR=lib` keeps libs in `/usr/lib`
      (not the triplet dir) so prime globs + LD_LIBRARY_PATH stay arch-agnostic
- [x] **`rockcraft pack` fully green in-rock** -- llama + go/cgo link + `bin/` output + pack
      all succeed (CI "Build base rock" passed). the whole rock design builds.
- [x] runtime: `LD_LIBRARY_PATH` covers both triplets (staged libstdc++/libgomp land there)
- [x] `inject.sh`: `mkdir -p build/oci` before skopeo (fresh checkout has no `build/`;
      only worked locally b/c the dir lingered from prior runs)
- [x] **full build pipeline green in CI (both arches)**: pack + model-layer inject
      (skopeo surgery) + buildah multiarch + artifacts. bare-base rock **boots** under
      pebble; `test_boot` (frontend serves page + htmx) passes.
- [x] `test_chat` readiness: evaluator listens only after reassembly + 237M model load,
      so the frontend proxy 500s ("connection refused") if hit at t=0. poll /send past
      that phase (was firing instantly after only waiting on the frontend).
- [~] `test_chat` real in-rock inference: fix pushed; whether generation itself works
      in-rock (bare-base loader, ggml cpu at runtime) is what this finally proves.

## todo (needs a network-capable linux box w/ rockcraft -- CI now covers most)

- [ ] `hack/build.sh` end-to-end: fetch-model -> `rockcraft pack` -> inject -> repack
- [ ] confirm the go plugin emits to `bin/` (the `organize:` map assumes it) now that
      `source: .` copies the whole version dir (hack/, tests/) as the go part source
- [ ] confirm mainline llama.cpp @ `b10092` builds inside rockcraft's ubuntu build env
      (cmake part installs `libllama.so` + `libggml*.so` + headers; prime globs assume that)
      and loads the Q1_0 gguf in-rock
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
cd bonsai/1.7   # go module lives in the version dir now
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
