# bonsai-1.7B-rock

a bare-base [canonical rock](https://documentation.ubuntu.com/rockcraft/) that runs
[bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) on cpu. bind a host
port, get a chat window -- and an OpenAI-compatible API on the same port.

```
docker run --rm -p 8080:8080 bonsai:1.7   # then open http://localhost:8080
```

## layout

each rock version is a self-contained dir under `bonsai/<version>/` (currently
`bonsai/1.7/`). there is **no application source**: the rock is llama.cpp plus
the model, injected as oci layers. everything here is build machinery.

- `bonsai/1.7/rockcraft.yaml` -- the rock: bare base, one pebble service, llama.cpp
- `bonsai/1.7/hack/inject-layers.sh` -- one oci layer per gguf shard (the interesting bit)
- `bonsai/1.7/hack/build.sh` -- fetch+split model -> pack -> convert -> inject -> oci-archive
- `bonsai/1.7/hack/download-model.sh` -- pulls the gguf from huggingface into `.cache/`
- `bonsai/1.7/hack/split-model.sh` -- shards it with the pinned `llama-gguf-split`
- `bonsai/1.7/{makefile,spread.yaml,tests/spread}` -- local build + spread integration tests
- `.github/workflows/` -- CI: build (per-arch pack + inject, buildah multiarch) + spread test

## the one service

`llama-server` runs under pebble (every rock's entrypoint) and serves everything
on `:8080`:

- `/` -- llama.cpp's built-in chat web ui
- `/v1/models`, `/v1/chat/completions` -- OpenAI-compatible API, incl. streaming
  and tool-calls

nothing here is hand-rolled. earlier revisions carried a go evaluator (cgo ->
llama.cpp) and an htmx frontend; both were deleted once `llama-server` was in the
image doing the same jobs properly. the rock now ships zero first-party code.

## using it as a local OpenAI-compatible LLM

```
docker run --rm -p 8080:8080 bonsai:1.7
curl http://localhost:8080/v1/models
```

- base url: `http://localhost:8080/v1`
- model id: `bonsai-1.7b`

port, context size and alias are flags on the service `command:` in
`rockcraft.yaml` (currently `--port 8080 --ctx-size 8192 --alias bonsai-1.7b`)
rather than env vars -- change them there, or override the service with a pebble
layer.

> **expectations.** bonsai-1.7B at `Q1_0` is 1.125 bpw on a 1.7B model. it will
> answer, but agentic coding clients (opencode et al) lean hard on
> instruction-following and tool-calling, which a model this small and this
> heavily quantised does poorly. treat this as "the wiring works", not as a
> usable local coding model.

## the model is not in the rock (by design)

rockcraft packs app content into one squashed layer and gives you no control over
which file lands in which layer. we want the **237M** of weights in their own layers
so they (a) download as parallel blobs and (b) stay cached when only the app changes.

so `build.sh` does it after packing:

0. `download-model.sh` fetches the gguf from huggingface into `.cache/`, then
   `split-model.sh` shards it with `llama-gguf-split` (both idempotent + cached)
1. `rockcraft pack` -> `bonsai_1.7_amd64.rock` (an oci-archive), no model in it
2. `hack/inject.sh`: `skopeo copy oci-archive:... oci:build/oci` -> an oci layout on disk
3. `inject-layers.sh` tars+gzips each shard into its own layer at
   `/usr/share/bonsai/model-0000N-of-00004.gguf`, and splices them into the
   manifest + config **just below the app content layer** (manifest/diff_id surgery)
4. `skopeo copy oci:build/oci oci-archive:bonsai_1.7.rock` -> final image

CI (`.github/workflows/build.yaml`) does the same, but packs the base rock with the
`canonical/craft-actions/rockcraft-pack` action and then runs `split-model.sh` +
`inject.sh` per arch, stitching the two into a multiarch rock with `buildah`.

why not `umoci raw add-layer`: it only appends on **top**. placing layers *below*
the app layer needs editing the layer + `diff_ids` ordering directly, which the
script does with `jq` + `sha256sum` + `tar`.

**the shards are real ggufs, not byte slices.** `gguf-split` writes each one as a
valid gguf carrying split metadata, so llama.cpp loads the whole set when pointed
at shard 1 -- `--model /usr/share/bonsai/model-00001-of-00004.gguf`. nothing
reassembles anything at startup, and the rock needs no wrapper process to do it.
(an earlier design shipped raw `dd` slices and `cat`ed them back together on boot,
which cost a duplicate 237M write into the writable layer every first start.)

the splitter is pinned to the same llama.cpp release the rock builds -- `split-model.sh`
reads `source-tag` straight out of `rockcraft.yaml` -- so the shard format can never
drift from the server that reads it. the shard **count** is baked into the service
command, so the script fails the build if a split ever yields a different number.

> note on "parallel download": the speedup comes from the **split into 4 blobs**,
> not the position. blob digests are content-addressed, so a layer caches the same
> whether it sits high or low. we still inject below the app layer for clean
> separation + stable model layers across app rebuilds, as specced.

## building

**must build on linux** (rockcraft is linux-only; on macos only the model
download/split and the injection script can be exercised). on a machine with
rockcraft:

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
- the rock boots under pebble and serves a chat ui + real inference end to end

> note: CI proved the above against the previous architecture (a go frontend in
> front of `llama-server`). the move to `llama-server` alone -- its embedded web
> ui, one service, no first-party code -- has not had a green run yet.

validated on the macos dev box:
- `bonsai.py` runs the same Q1_0 gguf through stock `llama-cpp-python` (a plain
  **mainline** llama.cpp build) and works -- so no fork is needed (see below).
- `inject-layers.sh` end-to-end on a synthetic oci layout: blob integrity, chain
  resolution, 5-layer ordering, digest/diff_id consistency
- **the shard scheme itself**: `llama-gguf-split` at the pinned tag produces 4
  balanced shards (67/61/60/58M), and `llama-server --model ...-00001-of-00004.gguf`
  loads the set and generates -- verified directly, outside the rock

resolved unknowns:
- **quant**: `Q1_0` = prism-ml's 1-bit g128 (ggml type 41 / file_type 40), qwen3 arch.
  **mainline llama.cpp loads it** (proven by `bonsai.py`). the rock builds mainline
  (`github.com/ggml-org/llama.cpp`); the fork the design first assumed is not used.

NOT yet validated:
- the `llm` service in-rock -- that `llama-server` builds there, and loads the
  shards from their oci layers. covered by `tests/spread/general/test_openai_api`.
- **the embedded web ui** -- `LLAMA_BUILD_UI=ON` relies on `LLAMA_USE_PREBUILT_UI`
  fetching the prebuilt front end from a HuggingFace bucket at build time. that is
  a build-time network dependency; if the bucket is unavailable the build may fall
  back to needing a javascript toolchain. covered by `tests/spread/general/test_boot`.

## known risk hotspots

- **bare base + shared libs** -- `llama-server` is C++ and dynamically linked, so it
  needs the ELF interp plus `libstdc++`/`libgomp`/glibc staged (`runtime-libs` part,
  and `LD_LIBRARY_PATH` on the service covers both arch triplet dirs). the go
  binaries are `CGO_ENABLED=0` static, so they carry no such dependency.
- **build time** -- `LLAMA_BUILD_TOOLS=ON` (needed for `llama-server`) builds every
  llama.cpp tool, though only the server is primed. that is the bulk of CI time.
- **memory** -- `--ctx-size` defaults to 8192 for agentic clients; the KV cache at
  that size is the main memory knob.
- **shard count is baked in** -- the service command names `model-00001-of-00004.gguf`
  literally. `split-model.sh` asserts the split produced exactly that many, so a
  changed model or split config fails the build instead of shipping a dead path.
