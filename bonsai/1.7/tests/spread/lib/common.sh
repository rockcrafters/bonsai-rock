# Set bash options
set -eux

source defer.sh

# Translate a /bonsai/... path (inside this test container) to the
# equivalent path on the host docker daemon. Needed because the docker
# socket is shared with the host -- bind mounts resolve there, not
# against this container's filesystem. (kept for tests that mount; the
# rock tests below reach the rock over the bridge and do not need it.)
function to_host() {
    local p="$1"
    printf '%s' "${p/#\/bonsai/$SPREAD_WORKDIR_HOST}"
}

# Run the rock-under-test detached and echo its bridge IP. Both this
# sshd test container and the rock run on the host daemon's default
# bridge, so the rock's pebble services are reachable by IP. $1 is a
# name suffix (e.g. `boot` -> container `test_bonsai_boot`). Cleanup is
# the caller's job:
#   defer "docker rm --force $name &>/dev/null || true" EXIT
function launch_rock() {
    local name="test_bonsai"
    [ -n "${1:-}" ] && name="${name}_$1"
    docker rm -f "$name" &>/dev/null || true
    docker run -d --name "$name" "$IMAGE_NAME:latest" > /dev/null
    docker inspect "$name" \
        --format '{{.NetworkSettings.Networks.bridge.IPAddress}}'
}

# Poll an http url until it answers 2xx or the attempt budget runs out.
# $1 url, $2 attempts (default 60), $3 sleep seconds (default 2).
function wait_http() {
    local url="$1" tries="${2:-60}" nap="${3:-2}" i
    for ((i = 0; i < tries; i++)); do
        if curl -fsS -o /dev/null "$url"; then
            return 0
        fi
        sleep "$nap"
    done
    printf 'timed out waiting for %s\n' "$url" >&2
    return 1
}
