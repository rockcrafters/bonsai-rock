# bonsai-1.7B-rock

a bare-base [canonical rock](https://documentation.ubuntu.com/rockcraft/) that runs
[bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) on cpu and serves a
tiny htmx chat client. bind a host port, get a chat window.

```
docker run --rm -p 8080:8080 bonsai:1.7   # then open http://localhost:8080
```

## layout

the go app lives at the repo root under `go/`; each rock version is a
self-contained dir under `bonsai/<version>/` (currently `bonsai/1.7/`).

- `go/cmd/frontend`   -- pure-go htmx chat ui, proxies prompts to the evaluator
- `go/cmd/evaluator`  -- loads the gguf (cgo -> llama.cpp), serves `POST /complete`
- `go/internal/llama` -- minimal cgo wrapper over llama.cpp's C API
   - `llama_cgo.go`  (linux+cgo) real inference
   - `llama_stub.go` (everything else) so the go logic builds/vets on macos
- `bonsai/1.7/rockcraft.yaml` -- the rock: bare base, 2 pebble services, llama.cpp libs
- `bonsai/1.7/hack/inject-layers.sh` -- splits the gguf into 4 oci layers (the interesting bit)
- `bonsai/1.7/hack/build.sh` -- fetch model -> pack -> convert -> inject -> oci-archive
- `bonsai/1.7/hack/download-model.sh` -- pulls the gguf from huggingface into `.cache/`
- `bonsai/1.7/{makefile,spread.yaml,tests/spread}` -- local build + spread integration tests
- `.github/workflows/` -- CI: build (per-arch pack + inject, buildah multiarch) + spread test

## the two services

both run under pebble (every rock's entrypoint):

- **evaluator** (`:8081`, localhost only) loads the model, one completion per request.
- **frontend** (`:8080`, the port you bind) serves the chat ui + vendored htmx,
  posts each turn to the evaluator, swaps the reply into the log.

## the model is not in the rock (by design)

rockcraft packs app content into one squashed layer and gives you no control over
which file lands in which layer. we want the **237M** of weights in their own layers
so they (a) download as parallel blobs and (b) stay cached when only the app changes.

so `build.sh` does it after packing:

0. `download-model.sh` fetches the gguf from huggingface into `.cache/` (idempotent)
1. `rockcraft pack` -> `bonsai_1.7_amd64.rock` (an oci-archive), no model in it
2. `hack/inject.sh`: `skopeo copy oci-archive:... oci:build/oci` -> an oci layout on disk
3. `inject-layers.sh` splits the gguf into 4 chunks, tars+gzips each into its own
   layer at `/usr/share/bonsai/<model>.part0[0-3]`, and splices them into the
   manifest + config **just below the app content layer** (manifest/diff_id surgery)
4. `skopeo copy oci:build/oci oci-archive:bonsai_1.7.rock` -> final image

CI (`.github/workflows/build.yaml`) does the same, but packs the base rock with the
`canonical/craft-actions/rockcraft-pack` action and then runs `download-model.sh` +
`inject.sh` per arch, stitching the two into a multiarch rock with `buildah`.

why not `umoci raw add-layer`: it only appends on **top**. placing layers *below*
the app layer needs editing the layer + `diff_ids` ordering directly, which the
script does with `jq` + `sha256sum` + `tar`.

on startup the evaluator `cat`s `/usr/share/bonsai/*.part*` (lexical order) back
into `/var/lib/bonsai/model.gguf` (once, cached across restarts) and mmap-loads it.

> note on "parallel download": the speedup comes from the **split into 4 blobs**,
> not the position. blob digests are content-addressed, so a layer caches the same
> whether it sits high or low. we still inject below the app layer for clean
> separation + stable model layers across app rebuilds, as specced.

## building

**must build on linux** (rockcraft is linux-only; this repo was developed on macos
where only the go frontend + the injection script can be exercised). on a machine
with rockcraft:

```
cd bonsai/1.7
make build      # fetch model (-> .cache/) + pack + inject -> bonsai_1.7.rock
make test       # build the spread test image + run the integration tests
make help       # list make targets
```

or from the repo root, delegating to every version dir (`VERSION=1.7` for one):

```
make build            # == make -C bonsai/1.7 build
make VERSION=1.7 test
make list             # show the version dirs
```

the model is downloaded from huggingface automatically; drop a copy at the repo
root (or in `.cache/`) to skip the download.

## what's validated vs not

validated on the macos dev box:
- **real inference**: reassembled the 4 chunks (byte-exact original sha), loaded the
  Q1_0 qwen3 gguf, got coherent completions; full stack frontend -> evaluator -> reply.
- `bonsai.py` runs the same Q1_0 gguf through stock `llama-cpp-python` (a plain
  **mainline** llama.cpp build) and works -- so no fork is needed (see below).
- frontend builds + runs; `/`, `/static/htmx.min.js`, `POST /send` all work
- both go binaries build; `go vet` clean; `GOOS=linux` cross-build ok
- `inject-layers.sh` end-to-end on a synthetic oci layout: blob integrity, chain
  resolution, 5-layer ordering, digest/diff_id consistency, **byte-exact reassembly**

resolved unknowns:
- **quant**: `Q1_0` = prism-ml's 1-bit g128 (ggml type 41 / file_type 40), qwen3 arch.
  **mainline llama.cpp loads it** (proven by `bonsai.py`). the rock builds mainline
  (`github.com/ggml-org/llama.cpp`); the fork the design first assumed is not used.
- **C API**: the cgo wrapper already targets current mainline (vocab-based tokenize,
  `llama_memory_clear`/`llama_get_memory`, `llama_model_chat_template`) -- unchanged.

NOT yet validated (needs linux w/ network + rockcraft -- an lxc/vm):
- pin `source-tag: bNNNN` in `rockcraft.yaml` to the exact llama.cpp build tag that
  the known-good `llama-cpp-python` vendors (the version `bonsai.py` proved works)
- `rockcraft pack` itself (part names, go plugin output path `/bin` vs `/usr/bin`,
  bare-base staging of libc/loader; `source: ../../go` relative path resolving)
- mainline llama.cpp building cleanly *inside* rockcraft's ubuntu build env
- skopeo consuming the hand-edited manifest (OCI validators are picky; the one lxc
  tried had no egress so apt-install skopeo failed)
- bare-base dynamic-loader path (`/lib64/ld-linux-*.so.2`) resolving at runtime

## known risk hotspots

- **bare base + glibc loader** (highest now) -- dynamically-linked binaries need the
  ELF interp at its baked-in path; bare rocks skip usrmerge. may need a `/lib64`
  symlink staged, plus `libstdc++`/`libgomp` (pulled in by the C++ llama.cpp libs).
- **go plugin install dir** -- `organize:` maps `bin/*` to `/usr/bin`; confirm the
  rockcraft go plugin actually emits to `bin/`.
- **mainline build inside rockcraft** -- the cmake part must install `libllama.so` +
  `libggml*.so` and the headers to the stage; prime globs assume that layout. lower
  risk than the fork was (mainline is well-trodden), but still needs a green pack.
