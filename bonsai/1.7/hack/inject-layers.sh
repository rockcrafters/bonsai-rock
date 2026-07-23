#!/usr/bin/env bash
# inject-layers.sh -- split a gguf into N chunks and insert them as N separate
# oci layers *just below* the topmost (app content) layer of an oci-layout image.
#
# why direct oci surgery and not `umoci raw add-layer`: umoci only appends layers
# on TOP. we want the model layers BELOW the app layer (stable across app
# rebuilds, parallel blob downloads), which means editing the manifest + config
# layer/diff_id ordering by hand. skopeo (rockcraft.skopeo) still does the
# oci-archive <-> oci-layout transport in build.sh; this script is pure surgery.
#
# usage: inject-layers.sh <oci-layout-dir> <ref-tag> <model-file> <n-chunks> <dest-dir-in-image>
#   e.g. inject-layers.sh build/oci bonsai ./Bonsai-1.7B-Q1_0.gguf 4 usr/share/bonsai
set -euo pipefail

OCI_DIR=${1:?oci layout dir}
TAG=${2:?image ref tag}
MODEL=${3:?model gguf path}
NCHUNKS=${4:?number of chunks}
DEST=${5:-usr/share/bonsai}

BLOBS="$OCI_DIR/blobs/sha256"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bonsai-inject.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# sha256 helper (linux: sha256sum, macos dev: shasum -a 256)
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# deterministic tar of a single staged file tree -> stdout (uncompressed).
# GNU tar (the linux build box) gets reproducibility flags; bsdtar (macos dev)
# falls back to a plain tar -- fine for validation, the rock is built on linux.
TARBIN=${TARBIN:-tar}
if "$TARBIN" --version 2>/dev/null | grep -qi 'gnu tar'; then
  tar_repro() { "$TARBIN" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - -C "$1" .; }
else
  tar_repro() { "$TARBIN" -cf - -C "$1" .; }
fi

modelname=$(basename "$MODEL")
size=$(stat -c%s "$MODEL" 2>/dev/null || stat -f%z "$MODEL")
chunk=$(( (size + NCHUNKS - 1) / NCHUNKS ))
echo ">> model $modelname = $size bytes -> $NCHUNKS chunks of ~$chunk"

# --- resolve current manifest + config from the oci layout -------------------
manifest_digest=$(jq -r '.manifests[0].digest' "$OCI_DIR/index.json" | sed 's/^sha256://')
manifest="$BLOBS/$manifest_digest"
config_digest=$(jq -r '.config.digest' "$manifest" | sed 's/^sha256://')
config="$BLOBS/$config_digest"

# arrays we will splice into (as compact json)
new_layers=$(jq -c '.layers' "$manifest")
new_diffids=$(jq -c '.rootfs.diff_ids' "$config")
new_history=$(jq -c '.history // []' "$config")

# --- build one layer per chunk ----------------------------------------------
for i in $(seq 0 $((NCHUNKS - 1))); do
  idx=$(printf '%02d' "$i")
  stage="$WORK/stage$idx/$DEST"
  mkdir -p "$stage"
  # carve chunk i out of the model with dd
  dd if="$MODEL" of="$stage/$modelname.part$idx" bs="$chunk" skip="$i" count=1 status=none

  raw="$WORK/layer$idx.tar"
  tar_repro "$WORK/stage$idx" > "$raw"
  diffid=$(sha256 "$raw")                       # diff_id = sha256(uncompressed tar)
  gzip -n -6 -c "$raw" > "$raw.gz"
  digest=$(sha256 "$raw.gz")                     # blob digest = sha256(gzip)
  lsize=$(stat -c%s "$raw.gz" 2>/dev/null || stat -f%z "$raw.gz")

  cp "$raw.gz" "$BLOBS/$digest"                  # store the blob
  echo ">> chunk $idx: diffid=${diffid:0:12} digest=${digest:0:12} size=$lsize"

  # splice this chunk BEFORE the last element (the app content layer)
  new_layers=$(echo "$new_layers" | jq -c \
    --arg d "sha256:$digest" --argjson s "$lsize" \
    '.[:-1] + [{mediaType:"application/vnd.oci.image.layer.v1.tar+gzip", digest:$d, size:$s}] + .[-1:]')
  new_diffids=$(echo "$new_diffids" | jq -c \
    --arg d "sha256:$diffid" '.[:-1] + [$d] + .[-1:]')
  new_history=$(echo "$new_history" | jq -c \
    --arg c "bonsai model chunk $idx" '.[:-1] + [{created_by:$c, comment:"injected by inject-layers.sh"}] + .[-1:]')
done

# --- write updated config blob ----------------------------------------------
newcfg="$WORK/config.json"
jq -c --argjson d "$new_diffids" --argjson h "$new_history" \
  '.rootfs.diff_ids = $d | .history = $h' "$config" > "$newcfg"
newcfg_digest=$(sha256 "$newcfg")
newcfg_size=$(stat -c%s "$newcfg" 2>/dev/null || stat -f%z "$newcfg")
cp "$newcfg" "$BLOBS/$newcfg_digest"

# --- write updated manifest blob (new layers + new config ref) --------------
newman="$WORK/manifest.json"
jq -c --argjson l "$new_layers" --arg cd "sha256:$newcfg_digest" --argjson cs "$newcfg_size" \
  '.layers = $l | .config.digest = $cd | .config.size = $cs' "$manifest" > "$newman"
newman_digest=$(sha256 "$newman")
newman_size=$(stat -c%s "$newman" 2>/dev/null || stat -f%z "$newman")
cp "$newman" "$BLOBS/$newman_digest"

# --- point index.json at the new manifest -----------------------------------
tmpidx="$WORK/index.json"
jq -c --arg d "sha256:$newman_digest" --argjson s "$newman_size" \
  '.manifests[0].digest = $d | .manifests[0].size = $s' "$OCI_DIR/index.json" > "$tmpidx"
cp "$tmpidx" "$OCI_DIR/index.json"

echo ">> done. new manifest sha256:${newman_digest:0:12}, ref=$TAG"
echo ">> layer order now: [<base layers>] [4x model chunk] [app content]"
