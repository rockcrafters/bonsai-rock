set -e

function main() {
    flavour=$(echo $SPREAD_SYSTEM | cut -d- -f1,2)
    arch=$(echo $SPREAD_SYSTEM | cut -d- -f3)
    image="sshd-$flavour-$arch"

    # we cannot filter by IP address directly, so we need to find the container by inspecting all containers
    container_name=""
    for cid in $(docker ps -a --filter "network=bridge" --format '{{.ID}}'); do
        cname=$(docker inspect "$cid" --format '{{.Name}}' | sed 's/^\/\(.*\)/\1/')
        cip=$(docker inspect "$cid" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' || echo "")
        if [ "$cip" == "$SPREAD_SYSTEM_ADDRESS" ]; then
            container_name="$cname"
            break
        fi
    done

    # If we found a matching container, remove it + its host workdir
    if [ -n "$container_name" ]; then
        workdir=$(docker inspect "$container_name" \
            --format '{{ index .Config.Labels "spread.workdir" }}' 2>/dev/null || echo "")
        echo "Removing container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || true
        if [ -n "$workdir" ] && [[ "$workdir" == /tmp/spread-bonsai* ]] && [ -d "$workdir" ]; then
            echo "Removing workdir: $workdir"
            # See allocate: bind-mount contents are root-owned, so wipe
            # via a throwaway container before rmdir on the host.
            docker run --rm -v "$workdir:/x" --entrypoint sh "$image" -c \
                'rm -rf /x/* /x/.[!.]* /x/..?* 2>/dev/null || true' &>/dev/null || true
            rm -rf "$workdir" 2>/dev/null || true
        fi
    else
        echo "No container found with IP address: $SPREAD_SYSTEM_ADDRESS"
        exit 1
    fi
}

main
