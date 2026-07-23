function main() {
    flavour=$(echo $SPREAD_SYSTEM | cut -d- -f1,2)
    arch=$(echo $SPREAD_SYSTEM | cut -d- -f3)
    # precompiled docker images for amd64 and arm64
    image="sshd-$flavour-$arch"
    echo "Using image: $image"

    # Add random suffix to container name for uniqueness
    random_suffix=$(head /dev/urandom | tr -dc a-f0-9 | head -c8)
    container_name="${SPREAD_SYSTEM}-${random_suffix}"

    # Host dir bound to /bonsai inside the test container. Spread syncs
    # the project into /bonsai; mounting from the host means inner
    # containers spawned via the shared docker socket can bind-mount
    # the same content -- after translating the /bonsai prefix to the
    # host path (see SPREAD_WORKDIR_HOST in spread.yaml + to_host in
    # tests/spread/lib/common.sh).
    # Single fixed path because workers=1; revisit if workers grow.
    workdir="/tmp/spread-bonsai"
    # Inner containers (via shared docker socket) run as root by
    # default; files written to the bind mount end up root-owned on
    # the host. A previous run's leftovers cannot be removed as the
    # host user, so nuke via a throwaway container that runs as root.
    if [ -d "$workdir" ]; then
        docker run --rm -v "$workdir:/x" --entrypoint sh "$image" -c 'rm -rf /x/* /x/.[!.]* /x/..?* 2>/dev/null || true'
    fi
    rm -rf "$workdir" 2>/dev/null || true
    mkdir -p "$workdir"

    # remove any existing container with the same name
    docker rm -f $container_name 2>/dev/null || true

    docker run \
        --rm \
        --platform "linux/$arch" \
        --privileged \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$workdir:/bonsai" \
        --label "spread.workdir=$workdir" \
        -e DEBIAN_FRONTEND=noninteractice \
        -e "usr=$SPREAD_SYSTEM_USERNAME" \
        -e "pass=$SPREAD_SYSTEM_PASSWORD" \
        --name "$container_name" \
        -d "$image"

    until docker exec "$container_name" pgrep sshd; do sleep 1; done

    ADDRESS "$(docker inspect "$container_name" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')"
}

main
