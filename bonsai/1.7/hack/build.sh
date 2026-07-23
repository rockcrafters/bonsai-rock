#!/usr/bin/env bash
# build.sh -- full local pipeline: fetch the model, pack the rock, inject the
# 4 model-chunk layers below the app content layer, emit a runnable image.
#
# run on linux with rockcraft installed (this mac can't -- see README). the
# bundled skopeo ships with the rockcraft snap as rockcraft.skopeo. CI does the
# same steps but packs via the craft-actions action and then calls inject.sh.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

OUT=${OUT:-bonsai_1.7.rock}   # final injected oci-archive (a .rock is one)
IMG_TAG=bonsai

printf '== fetch model ==\n'
MODEL=$(hack/download-model.sh)
printf 'model: %s\n' "$MODEL"

printf '== rockcraft pack ==\n'
rockcraft pack
ROCK=$(ls -t bonsai_1.7_*.rock | head -1)
printf 'packed: %s\n' "$ROCK"

MODEL="$MODEL" OUT="$OUT" hack/inject.sh "$ROCK" "$OUT"
# drop the base (model-less) rock so the injected one is the only bonsai*.rock
rm -f "$ROCK"

printf '\nload + run, e.g.:\n'
printf '  rockcraft.skopeo copy oci-archive:%s docker-daemon:%s:1.7\n' "$OUT" "$IMG_TAG"
printf '  docker run --rm -p 8080:8080 %s:1.7\n' "$IMG_TAG"
printf 'then open http://localhost:8080\n'
