#!/usr/bin/env bash
# the `llm` service (llama-server) must expose an OpenAI-compatible api on
# :8080 -- what makes the rock usable as a local model for opencode et al.
# also proves llama.cpp loads the gguf-split shards from their oci layers when
# pointed at shard 1, with nothing reassembling them.

source common.sh

name=test_bonsai_openai
ip=$(launch_rock openai)
trap 'docker logs "$name" 2>&1 | tail -80 || true; docker rm --force "$name" &>/dev/null || true' EXIT

# llama-server loads the model before it answers; give it room.
wait_http "http://$ip:8080/v1/models" 60 3

# the --alias we pass llama-server is the model id clients configure
curl -fsS "http://$ip:8080/v1/models" | grep -Fiq 'bonsai-1.7b'

# a real (tiny) completion through the OpenAI route
reply=$(curl -fsS --max-time 330 -X POST "http://$ip:8080/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"bonsai-1.7b","max_tokens":8,"messages":[{"role":"user","content":"mooo! 🐄"}]}')

printf '%s' "$reply" | grep -Fiq '"choices"'
# content must be present (value itself may be anything the model emits)
printf '%s' "$reply" | grep -q '"content"'
