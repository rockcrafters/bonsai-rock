function main() {
    flavour=$(echo $SPREAD_SYSTEM | cut -d- -f1,2)
    arch=$(echo $SPREAD_SYSTEM | cut -d- -f3)
    # precompiled sshd images for amd64 and arm64 (see hack/Dockerfile.sshd-*)
    image="sshd-$flavour-$arch"
    echo "Using image: $image"

    # unique container name per allocation
    random_suffix=$(head /dev/urandom | tr -dc a-f0-9 | head -c8)
    container_name="${SPREAD_SYSTEM}-${random_suffix}"
    docker rm -f $container_name 2>/dev/null || true

    # --privileged + the shared docker socket let the tests `docker run` the
    # rock-under-test on the host daemon (dind). spread rsyncs the project into
    # the container's own /bonsai over ssh, so no host bind mount is needed.
    docker run \
        --rm \
        --platform "linux/$arch" \
        --privileged \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --name "$container_name" \
        -d "$image"

    until docker exec "$container_name" pgrep sshd >/dev/null; do sleep 1; done

    ADDRESS "$(docker inspect "$container_name" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')"
}

main
