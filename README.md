# bonsai-1.7B-rock

bare-base [rock](https://documentation.ubuntu.com/rockcraft/) that *bundles* and
runs [prism-ml/bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) model
through llama cpu server. bind a host port, get a chat window -- and an
OpenAI-compatible API on the same port.

```
docker run --rm -p 8080:8080 ghcr.io/rockcrafters/bonsai-rock/bonsai:1.7B
curl http://localhost:8080/v1/models
```

`llama-server` runs under pebble and serves everything on `:8080`:

- `/` -- llama.cpp's built-in chat web ui
- `/v1/models`, `/v1/chat/completions` -- OpenAI-compatible API, incl. streaming and tool-calls

## links

- https://github.com/PrismML-Eng/Bonsai-demo
- https://github.com/ggml-org/llama.cpp

## license

| component | licence | in the image |
| --- | --- | --- |
| bonsai-1.7B weights | Apache-2.0 | `/usr/share/doc/bonsai-1.7B/{LICENSE,NOTICE.txt,PROVENANCE}` |
| llama.cpp (`llama-server`, statically linked) | MIT | `/usr/share/doc/llama.cpp/LICENSE` |
| glibc, libstdc++, libgomp | LGPL / GPL+exception | `/usr/share/doc/<pkg>/copyright` |
