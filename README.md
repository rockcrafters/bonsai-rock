# bonsai-1.7B-rock

bare-base [rock](https://documentation.ubuntu.com/rockcraft/) that *bundles* and runs
[bonsai-1.7B](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) llama cpu server. bind
a host port, get a chat window -- and an OpenAI-compatible API on the same port.

```
docker run --rm -p 8080:8080 ghcr.io/rockcrafters/bonsai-rock/bonsai:1.7
curl http://localhost:8080/v1/models
```

`llama-server` runs under pebble and serves everything on `:8080`:

- `/` -- llama.cpp's built-in chat web ui
- `/v1/models`, `/v1/chat/completions` -- OpenAI-compatible API, incl. streaming and tool-calls

> this is a fun stunt / proof-of principle. bonsai-1.7B at is a 1-bit model which
> is very much optimised for size. its amazing that it answers at all. don't expect
> great results.


## licensing + provenance

| component | licence | in the image |
| --- | --- | --- |
| bonsai-1.7B weights | Apache-2.0 | `/usr/share/doc/bonsai-1.7B/{LICENSE,NOTICE.txt,PROVENANCE}` |
| llama.cpp (`llama-server`, statically linked) | MIT | `/usr/share/doc/llama.cpp/LICENSE` |
| glibc, libstdc++, libgomp | LGPL / GPL+exception | `/usr/share/doc/<pkg>/copyright` |
