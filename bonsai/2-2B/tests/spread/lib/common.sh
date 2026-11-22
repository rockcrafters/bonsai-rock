# Set bash options
set -eux

function launch_rock() {
    local name="test_bonsai"
    [ -n "${1:-}" ] && name="${name}_$1"
    docker rm -f "$name" &>/dev/null || true
    docker run -d --name "$name" "$IMAGE_NAME:latest" > /dev/null
    docker inspect "$name" \
        --format '{{.NetworkSettings.Networks.bridge.IPAddress}}'
}

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
