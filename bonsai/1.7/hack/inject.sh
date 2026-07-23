#!/usr/bin/env bash
# inject.sh -- take an already-packed base rock (oci-archive) and produce a
# final oci-archive with the 4 model-chunk layers spliced in below the app
# content layer. this is the half of build.sh that runs *after* the rock is
# packed, so CI (which packs via the craft-actions rockcraft-pack action) can
# reuse it without re-packing.
#
# usage: inject.sh <base-rock> [<out-oci-archive>]
#   defaults: out = bonsai-1.7B.oci   model = hack/download-model.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

ROCK=${1:?path to the packed base rock (oci-archive)}
OUT=${2:-bonsai-1.7B.oci}
NCHUNKS=${NCHUNKS:-4}
IMG_TAG=bonsai

SKOPEO=${SKOPEO:-rockcraft.skopeo}
command -v "$SKOPEO" >/dev/null || SKOPEO=skopeo   # fall back to a system skopeo

MODEL=${MODEL:-$(hack/download-model.sh)}
[ -f "$MODEL" ] || { printf 'model not found: %s\n' "$MODEL" >&2; exit 1; }

printf '== 1/3 rock -> oci layout ==\n'
rm -rf build/oci
"$SKOPEO" copy "oci-archive:$ROCK" "oci:build/oci:$IMG_TAG"

printf '== 2/3 inject %s model layers ==\n' "$NCHUNKS"
hack/inject-layers.sh build/oci "$IMG_TAG" "$MODEL" "$NCHUNKS" usr/share/bonsai

printf '== 3/3 oci layout -> oci-archive (%s) ==\n' "$OUT"
rm -f "$OUT"
"$SKOPEO" copy "oci:build/oci:$IMG_TAG" "oci-archive:$OUT:$IMG_TAG"

printf '\ndone -> %s\n' "$OUT"
