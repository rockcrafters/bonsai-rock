set -e

function main() {
    # spread hands us the system's IP, not a container id, so find the container
    # on the bridge whose ip matches and remove it.
    container_name=""
    for cid in $(docker ps -a --filter "network=bridge" --format '{{.ID}}'); do
        cip=$(docker inspect "$cid" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' || echo "")
        if [ "$cip" == "$SPREAD_SYSTEM_ADDRESS" ]; then
            container_name=$(docker inspect "$cid" --format '{{.Name}}' | sed 's/^\///')
            break
        fi
    done

    if [ -n "$container_name" ]; then
        echo "Removing container: $container_name"
        docker rm -f "$container_name" 2>/dev/null || true
    else
        echo "No container found with IP address: $SPREAD_SYSTEM_ADDRESS"
        exit 1
    fi
}

main
