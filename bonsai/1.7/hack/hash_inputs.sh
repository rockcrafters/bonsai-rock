#!/usr/bin/env bash
# hash_inputs.sh -- single sha256 over every local input that affects the rock
# build (rockcraft.yaml, the injection scripts, and the go sources). the
# makefile stores this in .rock.stamp so a repack only fires when an input
# actually changed. stdout: hex digest only.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

# everything that shapes the build. there is no application source any more --
# the rock is llama.cpp plus the injected model layers -- so this is just the
# rock definition and the scripts that assemble it.
LOCAL=(
    rockcraft.yaml
    hack/inject-layers.sh
    hack/inject.sh
    hack/download-model.sh
    hack/split-model.sh
)

sha256sum "${LOCAL[@]}" | sha256sum | cut -d' ' -f1
