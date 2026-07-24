# bonsai-1.7B-rock

[![CI](https://github.com/rockcrafters/bonsai-rock/actions/workflows/ci.yaml/badge.svg)](https://github.com/rockcrafters/bonsai-rock/actions/workflows/ci.yaml)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![rocks](https://img.shields.io/badge/%F0%9F%AA%A8-rocks-E95420)](https://documentation.ubuntu.com/rockcraft/)
[![ghcr](https://img.shields.io/badge/ghcr-bonsai-blue?logo=docker)](https://github.com/rockcrafters/bonsai-rock/pkgs/container/bonsai-rock%2Fbonsai)
[![bonsai](https://img.shields.io/badge/bonsai-6aa84f?logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMTUiIHZpZXdCb3g9IjAgMCAyNCAxNSIgZmlsbD0iI2ZmZiIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48cGF0aCBkPSJNMTUuMTMwNCA2LjI1ODY0SDEyTDE0LjA4NyAxMC40MzExTDYuNzgyNjEgMTQuNjAzNUgxNi4xNzM5TDIwLjM0NzggMTAuNDMxMUwxNS4xMzA0IDYuMjU4NjRaIi8%2BPHBhdGggZD0iTTE2Ljc4MjYgNi4yNTg2NkgyNFY4LjM0NDg4SDE5LjQwMjJMMTYuNzgyNiA2LjI1ODY2WiIvPjxwYXRoIGQ9Ik0wIDYuMjU4NjZIMTAuODM3TDExLjg4MDQgOC4zNDQ4OEgwVjYuMjU4NjZaIi8%2BPHBhdGggZD0iTTUuMjE3MzkgMy4xMjkzM0gyMC44Njk2VjUuMjE1NTVINS4yMTczOVYzLjEyOTMzWiIvPjxwYXRoIGQ9Ik0xMC40MzQ4IDBIMTcuNzM5MVYyLjA4NjIySDEwLjQzNDhWMFoiLz48L3N2Zz4%3D&logoColor=white)](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf)

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

the Bonsai logo is (c) Prism ML, Inc., used under Apache-2.0 to identify the model.
