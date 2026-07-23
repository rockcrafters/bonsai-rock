#!/usr/bin/env bash
# download-model.sh -- ensure the bonsai gguf is present under the repo's
# .cache/ and echo its path on stdout. idempotent: reuses an existing copy
# (in .cache/ or at the repo root) when the byte size matches; only hits the
# network when nothing local is usable. diagnostics go to stderr so stdout
# stays a bare path (callable as MODEL=$(hack/download-model.sh)).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../../.." && pwd)
MODEL_REPO=${MODEL_REPO:-prism-ml/Bonsai-1.7B-gguf}
MODEL_FILE=${MODEL_FILE:-Bonsai-1.7B-Q1_0.gguf}
EXPECT_SIZE=${EXPECT_SIZE:-248302272}          # bytes of the original gguf
URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}?download=true"

CACHE="$REPO/.cache"
DEST="$CACHE/$MODEL_FILE"

_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1"; }

DOCS="$CACHE/model-docs"

# the model is Apache-2.0: section 4 requires we redistribute the licence and
# retain the NOTICE, so they ship in the rock alongside the weights. also record
# where the weights came from and what they hash to.
_fetch_docs() {
  mkdir -p "$DOCS"
  local f
  for f in LICENSE NOTICE.txt; do
    [ -s "$DOCS/$f" ] && continue
    printf 'fetching model %s...\n' "$f" >&2
    curl -fsSL --retry 3 -o "$DOCS/$f" \
      "https://huggingface.co/${MODEL_REPO}/resolve/main/$f"
  done
  # no timestamp: keep the build reproducible
  {
    printf 'bonsai-1.7B model provenance\n\n'
    printf 'source:  https://huggingface.co/%s\n' "$MODEL_REPO"
    printf 'file:    %s\n' "$MODEL_FILE"
    printf 'size:    %s bytes\n' "$(_size "$DEST")"
    printf 'sha256:  %s\n' "$(_sha256 "$DEST")"
    printf 'license: Apache-2.0 (see LICENSE and NOTICE.txt beside this file)\n'
    printf '\nthe weights are shipped as gguf-split shards, one oci layer each.\n'
  } > "$DOCS/PROVENANCE"
}

_sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# already cached at the right size -> done
if [ -f "$DEST" ] && [ "$(_size "$DEST")" = "$EXPECT_SIZE" ]; then
  printf 'reusing cached model: %s\n' "$DEST" >&2
  _fetch_docs
  printf '%s\n' "$DEST"
  exit 0
fi

mkdir -p "$CACHE"

# a good copy sitting at the repo root (the dev-box layout) -> link it in
ROOT_COPY="$REPO/$MODEL_FILE"
if [ -f "$ROOT_COPY" ] && [ "$(_size "$ROOT_COPY")" = "$EXPECT_SIZE" ]; then
  printf 'linking model from repo root: %s\n' "$ROOT_COPY" >&2
  ln -f "$ROOT_COPY" "$DEST" 2>/dev/null || cp "$ROOT_COPY" "$DEST"
  _fetch_docs
  printf '%s\n' "$DEST"
  exit 0
fi

printf 'downloading %s from huggingface (%s bytes)...\n' "$MODEL_FILE" "$EXPECT_SIZE" >&2
curl -fL --retry 3 -o "$DEST.part" "$URL"
mv "$DEST.part" "$DEST"

got=$(_size "$DEST")
if [ "$got" != "$EXPECT_SIZE" ]; then
  printf 'size mismatch: got %s, expected %s\n' "$got" "$EXPECT_SIZE" >&2
  exit 1
fi

_fetch_docs

printf 'downloaded: %s\n' "$DEST" >&2
printf '%s\n' "$DEST"
