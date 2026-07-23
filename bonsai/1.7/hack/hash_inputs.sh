#!/usr/bin/env bash
# hash_inputs.sh -- single sha256 over every local input that affects the rock
# build (rockcraft.yaml, the injection scripts, and the go sources). the
# makefile stores this in .rock.stamp so a repack only fires when an input
# actually changed. stdout: hex digest only.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

# local files under the version dir that shape the build
LOCAL=(
    rockcraft.yaml
    hack/inject-layers.sh
    hack/inject.sh
    hack/download-model.sh
)

{
    sha256sum "${LOCAL[@]}"
    # go module sources + embedded assets, wherever they sit under the version
    # dir (kept layout-agnostic so moving packages around doesn't break this).
    find . -path ./build -prune -o -type f \( -name '*.go' -o -name 'go.mod' \
        -o -name 'go.sum' -o -name '*.html' -o -name '*.js' \) -print0 \
        | sort -z | xargs -0 sha256sum
} | sha256sum | cut -d' ' -f1
