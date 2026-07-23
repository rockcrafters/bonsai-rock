#!/usr/bin/env bash
# full stack: POST a prompt to the frontend's /send, which calls llama-server's
# OpenAI api, running on the gguf shards loaded straight from their oci layers.
# exercises the whole rock end to end.

source common.sh
source defer.sh

name=test_bonsai_chat
ip=$(launch_rock chat)
defer "docker logs $name 2>&1 | tail -80 || true; docker rm --force $name &>/dev/null || true" EXIT

# frontend up (instant -- no model)
wait_http "http://$ip:8080/" 60 2

# llama-server loads the model before it listens on :8082, so until it's ready
# the frontend gets a connection refused and returns an inline
# "[error: ...connection refused...]". poll /send past that phase; once the llm
# service is up the call blocks on the (slow, cpu) generation and returns the
# real reply. --max-time matches the frontend's 5-min proxy timeout.
reply=""
for i in $(seq 1 40); do
    reply=$(curl -fsS --max-time 330 -X POST "http://$ip:8080/send" \
        --data-urlencode 'prompt=say hi in one word' || true)
    case "$reply" in
        *'connection refused'*) sleep 3; continue ;;  # evaluator still loading
    esac
    break
done

# the fragment carries both the echoed prompt and the bot reply div;
# assert the bot div exists and is non-empty.
printf '%s' "$reply" | grep -q 'class="msg bot"'
bot=$(printf '%s' "$reply" | sed -n 's/.*class="msg bot">\(.*\)<\/div>.*/\1/p')
[ -n "$bot" ] || { printf 'empty bot reply: %s\n' "$reply" >&2; exit 1; }
# a runtime eval error is surfaced inline as [error: ...] -- fail on it.
case "$bot" in
    \[error:*) printf 'evaluator error: %s\n' "$bot" >&2; exit 1 ;;
esac
