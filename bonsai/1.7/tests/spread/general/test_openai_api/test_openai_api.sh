#!/usr/bin/env bash
# the `llm` service (llmserve -> llama-server) must expose an OpenAI-compatible
# api on :8082 -- what makes the rock usable as a local model for opencode et al.

source common.sh
source defer.sh

name=test_bonsai_openai
ip=$(launch_rock openai)
defer "docker logs $name 2>&1 | tail -80 || true; docker rm --force $name &>/dev/null || true" EXIT

# llama-server reassembles the chunks + loads the gguf before it answers, so
# give it the same room the chat test gets.
wait_http "http://$ip:8082/v1/models" 60 3

# the alias we set (BONSAI_LLM_ALIAS) is the model id clients configure
curl -fsS "http://$ip:8082/v1/models" | grep -q 'bonsai-1.7b'

# a real (tiny) completion through the OpenAI route
reply=$(curl -fsS --max-time 330 -X POST "http://$ip:8082/v1/chat/completions" \
    -H 'content-type: application/json' \
    -d '{"model":"bonsai-1.7b","max_tokens":8,"messages":[{"role":"user","content":"say hi in one word"}]}')

printf '%s' "$reply" | grep -q '"choices"'
# content must be present (value itself may be anything the model emits)
printf '%s' "$reply" | grep -q '"content"'
