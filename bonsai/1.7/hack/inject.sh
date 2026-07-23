#!/usr/bin/env bash
# inject.sh -- take an already-packed base rock (oci-archive) and produce a
# final oci-archive with the gguf shards spliced in as layers below the app
# content layer. this is the half of build.sh that runs *after* the rock is
# packed, so CI (which packs via the craft-actions rockcraft-pack action) can
# reuse it without re-packing.
#
# usage: inject.sh <base-rock> [<out-oci-archive>]
#   the shards come from hack/split-model.sh (cached under .cache/shards)
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

ROCK=${1:?path to the packed base rock (oci-archive)}
OUT=${2:-bonsai_1.7.rock}
IMG_TAG=bonsai

SKOPEO=${SKOPEO:-rockcraft.skopeo}
command -v "$SKOPEO" >/dev/null || SKOPEO=skopeo   # fall back to a system skopeo

SHARD_DIR=${SHARD_DIR:-$(hack/split-model.sh)}
[ -d "$SHARD_DIR" ] || { printf 'shard dir not found: %s\n' "$SHARD_DIR" >&2; exit 1; }

printf '== 1/3 rock -> oci layout ==\n'
rm -rf build/oci
mkdir -p build/oci          # skopeo oci: transport needs the parent dir to exist
"$SKOPEO" copy "oci-archive:$ROCK" "oci:build/oci:$IMG_TAG"

printf '== 2/3 inject model shard layers ==\n'
hack/inject-layers.sh build/oci "$IMG_TAG" "$SHARD_DIR" usr/share/bonsai

printf '== 3/3 oci layout -> oci-archive (%s) ==\n' "$OUT"
rm -f "$OUT"
"$SKOPEO" copy "oci:build/oci:$IMG_TAG" "oci-archive:$OUT:$IMG_TAG"

printf '\ndone -> %s\n' "$OUT"
