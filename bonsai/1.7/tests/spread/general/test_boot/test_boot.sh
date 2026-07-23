#!/usr/bin/env bash
# boot the rock (single pebble service: llama-server) and check it serves its
# embedded chat web ui on :8080. generation itself is test_openai_api's job.

source common.sh
source defer.sh

name=test_bonsai_boot
ip=$(launch_rock boot)
defer "docker logs $name 2>&1 | tail -50 || true; docker rm --force $name &>/dev/null || true" EXIT

# llama-server loads the model before it listens, so allow for that.
wait_http "http://$ip:8080/" 60 3

# the built-in ui is served at the root. assert it is html rather than matching
# upstream's markup, which is theirs to change.
curl -fsS "http://$ip:8080/" | grep -qi '<html'
curl -fsS -o /dev/null -w '%{content_type}' "http://$ip:8080/" | grep -qi 'text/html'
