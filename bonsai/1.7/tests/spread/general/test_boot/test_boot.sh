#!/usr/bin/env bash
# boot the rock (pebble entrypoint, evaluator + frontend services) and
# check the frontend serves its page + the vendored htmx asset. no model
# inference here -- that is test_chat's job.

source common.sh
source defer.sh

name=test_bonsai_boot
ip=$(launch_rock boot)
defer "docker logs $name 2>&1 | tail -50 || true; docker rm --force $name &>/dev/null || true" EXIT

# frontend listens on :8080; give the services a moment to come up.
wait_http "http://$ip:8080/" 60 2

# the page and its title marker
curl -fsS "http://$ip:8080/" | grep -q '<h1>bonsai-1.7B</h1>'
curl -fsS "http://$ip:8080/" | grep -q '<title>bonsai chat</title>'

# vendored htmx served locally (no runtime CDN)
curl -fsS "http://$ip:8080/static/htmx.min.js" | grep -qi 'htmx'
