# bonsai-1.7B-rock

a bare-base [canonical rock](https://documentation.ubuntu.com/rockcraft/) that runs
[bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) on cpu and serves a
tiny htmx chat client. bind a host port, get a chat window.

```
docker run --rm -p 8080:8080 bonsai:1.7   # then open http://localhost:8080
```

## layout

each rock version is a self-contained dir under `bonsai/<version>/` (currently
`bonsai/1.7/`) holding the go module, rockcraft.yaml, build scripts and tests --
rockcraft only mounts the project subtree, so the go source lives alongside it.

- `bonsai/1.7/cmd/frontend`   -- pure-go htmx chat ui, calls the llm service's OpenAI api
- `bonsai/1.7/cmd/llmserve`   -- reassembles the chunks, then execs `llama-server`
- `bonsai/1.7/internal/model` -- shared, idempotent chunk reassembly
- `bonsai/1.7/rockcraft.yaml` -- the rock: bare base, 2 pebble services, llama.cpp libs
- `bonsai/1.7/hack/inject-layers.sh` -- splits the gguf into 4 oci layers (the interesting bit)
- `bonsai/1.7/hack/build.sh` -- fetch model -> pack -> convert -> inject -> oci-archive
- `bonsai/1.7/hack/download-model.sh` -- pulls the gguf from huggingface into `.cache/`
- `bonsai/1.7/{makefile,spread.yaml,tests/spread}` -- local build + spread integration tests
- `.github/workflows/` -- CI: build (per-arch pack + inject, buildah multiarch) + spread test

## the two services

both run under pebble (every rock's entrypoint):

- **llm** (`:8082`) llama.cpp's `llama-server` on the gguf -- does all the
  inference, and exposes an OpenAI-compatible API (see below).
- **frontend** (`:8080`, the port you bind) serves the chat ui + vendored htmx,
  posts each turn to the llm service, swaps the reply into the log.

there is deliberately no hand-rolled inference service: `llama-server` already
does it, with streaming and tool-calls. the go side is pure (`CGO_ENABLED=0`)
static binaries -- no cgo, no C toolchain, nothing linking llama.cpp.

## using it as a local OpenAI-compatible LLM

bind `:8082` and point any OpenAI-compatible client at it:

```
docker run --rm -p 8080:8080 -p 8082:8082 bonsai:1.7
curl http://localhost:8082/v1/models
```

- base url: `http://localhost:8082/v1`
- model id: `bonsai-1.7b` (set via `BONSAI_LLM_ALIAS`)
- `/v1/chat/completions` incl. streaming, courtesy of `llama-server`

tunables on the `llm` service: `BONSAI_LLM_PORT`, `BONSAI_LLM_CTX` (default 8192),
`BONSAI_LLM_ALIAS`, and `BONSAI_LLM_ARGS` as an escape hatch for any other
`llama-server` flag. the frontend takes `BONSAI_MAX_TOKENS`, `BONSAI_TEMP` and
`BONSAI_SYSTEM` for the requests it sends.

> **expectations.** bonsai-1.7B at `Q1_0` is 1.125 bpw on a 1.7B model. it will
> answer, but agentic coding clients (opencode et al) lean hard on
> instruction-following and tool-calling, which a model this small and this
> heavily quantised does poorly. treat this as "the wiring works", not as a
> usable local coding model.

`llmserve` reassembles the 4 model chunks before exec'ing `llama-server`.
that wrapper exists because pebble's `after:` only orders service *starts* (it
would not wait for a ~237M reassembly) and a bare base has no shell to script
"assemble then exec".

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

on startup `llmserve` `cat`s `/usr/share/bonsai/*.part*` (lexical order) back
into `/var/lib/bonsai/model.gguf` (once, cached across restarts), then hands it
to `llama-server`, which mmap-loads it.

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

validated in CI (both amd64 and arm64), via the spread suite:
- `rockcraft pack`, the 4-layer model injection, the buildah multiarch stitch
- the rock boots under pebble and the frontend serves its page + vendored htmx
- **real inference end to end**: prompt -> frontend -> llama-server -> reply

validated on the macos dev box:
- `bonsai.py` runs the same Q1_0 gguf through stock `llama-cpp-python` (a plain
  **mainline** llama.cpp build) and works -- so no fork is needed (see below).
- go binaries build; `go vet` clean; `GOOS=linux` cross-build ok
- `inject-layers.sh` end-to-end on a synthetic oci layout: blob integrity, chain
  resolution, 5-layer ordering, digest/diff_id consistency, **byte-exact reassembly**

resolved unknowns:
- **quant**: `Q1_0` = prism-ml's 1-bit g128 (ggml type 41 / file_type 40), qwen3 arch.
  **mainline llama.cpp loads it** (proven by `bonsai.py`). the rock builds mainline
  (`github.com/ggml-org/llama.cpp`); the fork the design first assumed is not used.

NOT yet validated:
- the `llm` service itself -- that `llama-server` builds in the rock and serves
  `/v1` there. this is new; `tests/spread/general/test_openai_api` covers it.

## known risk hotspots

- **bare base + shared libs** -- `llama-server` is C++ and dynamically linked, so it
  needs the ELF interp plus `libstdc++`/`libgomp`/glibc staged (`runtime-libs` part,
  and `LD_LIBRARY_PATH` on the service covers both arch triplet dirs). the go
  binaries are `CGO_ENABLED=0` static, so they carry no such dependency.
- **build time** -- `LLAMA_BUILD_TOOLS=ON` (needed for `llama-server`) builds every
  llama.cpp tool, though only the server is primed. that is the bulk of CI time.
- **memory** -- `BONSAI_LLM_CTX` defaults to 8192 for agentic clients; the KV cache
  at that size is the main memory knob.
