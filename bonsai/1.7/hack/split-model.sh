#!/usr/bin/env bash
# split-model.sh -- produce gguf-split shards of the bonsai model under
# .cache/shards/ and echo that directory on stdout.
#
# the shards are real ggufs (each carrying split metadata), not raw byte slices,
# so llama.cpp loads the whole set when pointed at shard 1 -- no reassembly in
# the rock at all. splitting has to happen host-side because the model never
# enters the rockcraft build.
#
# idempotent: reuses cached shards, and caches the splitter too. diagnostics go
# to stderr so stdout stays a bare path.
set -euo pipefail
cd "$(dirname "$0")/.."   # -> bonsai/1.7/

REPO=$(cd ../.. && pwd)
CACHE="$REPO/.cache"
SHARDS="$CACHE/shards"
PREFIX=${SHARD_PREFIX:-model}
NSHARDS=${NSHARDS:-4}
# 62M yields 4 well-balanced shards (67/61/60/58M) for this model; the splitter
# cuts on tensor boundaries, so the count is asserted below rather than assumed.
MAXSIZE=${SPLIT_MAX_SIZE:-62M}

_shard() { printf '%s/%s-%05d-of-%05d.gguf' "$SHARDS" "$PREFIX" "$1" "$NSHARDS"; }

# all shards already cached -> done
_have_all() {
    local i
    for ((i = 1; i <= NSHARDS; i++)); do
        [ -f "$(_shard "$i")" ] || return 1
    done
    return 0
}

# pin the splitter to the exact llama.cpp the rock builds, so the shard format
# can never drift from the server that reads it.
TAG=$(sed -n 's/^ *source-tag: *\(b[0-9][0-9]*\).*/\1/p' rockcraft.yaml | head -1)
[ -n "$TAG" ] || { printf 'could not read source-tag from rockcraft.yaml\n' >&2; exit 1; }

# .cache survives across CI runs, so cached shards must be invalidated when the
# split config (or the llama.cpp version that produced them) changes.
STAMP="$SHARDS/.split-config"
WANT="$TAG $PREFIX $NSHARDS $MAXSIZE"
if _have_all && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$WANT" ]; then
    printf 'reusing cached shards in %s\n' "$SHARDS" >&2
    printf '%s\n' "$SHARDS"
    exit 0
fi

case "$(uname -s):$(uname -m)" in
    (Linux:x86_64)  asset=ubuntu-x64 ;;
    (Linux:aarch64) asset=ubuntu-arm64 ;;
    (Darwin:arm64)  asset=macos-arm64 ;;
    (Darwin:x86_64) asset=macos-x64 ;;
    (*) printf 'no llama.cpp release asset for %s/%s\n' "$(uname -s)" "$(uname -m)" >&2; exit 1 ;;
esac

TOOLS="$CACHE/tools/$TAG-$asset"
SPLIT_BIN=$(find "$TOOLS" -type f -name 'llama-gguf-split' 2>/dev/null | head -1 || true)
if [ -z "$SPLIT_BIN" ]; then
    tarball="llama-$TAG-bin-$asset.tar.gz"
    url="https://github.com/ggml-org/llama.cpp/releases/download/$TAG/$tarball"
    printf 'fetching %s...\n' "$tarball" >&2
    mkdir -p "$TOOLS"
    curl -fL --retry 3 -o "$TOOLS/$tarball" "$url"
    tar -xzf "$TOOLS/$tarball" -C "$TOOLS"
    rm -f "$TOOLS/$tarball"
    SPLIT_BIN=$(find "$TOOLS" -type f -name 'llama-gguf-split' | head -1)
    [ -n "$SPLIT_BIN" ] || { printf 'llama-gguf-split not found in %s\n' "$tarball" >&2; exit 1; }
    chmod +x "$SPLIT_BIN"
fi

MODEL=${MODEL:-$(hack/download-model.sh)}
[ -f "$MODEL" ] || { printf 'model not found: %s\n' "$MODEL" >&2; exit 1; }

rm -rf "$SHARDS"
mkdir -p "$SHARDS"
printf 'splitting %s (max %s per shard)...\n' "$MODEL" "$MAXSIZE" >&2
# the shared libs ship alongside the binary in the release tarball
LD_LIBRARY_PATH="$(dirname "$SPLIT_BIN")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
DYLD_LIBRARY_PATH="$(dirname "$SPLIT_BIN")${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
    "$SPLIT_BIN" --split --split-max-size "$MAXSIZE" "$MODEL" "$SHARDS/$PREFIX" >&2

# the rock's service command names shard 1 of N literally, so a different count
# would silently ship a broken command -- fail loudly instead.
got=$(find "$SHARDS" -name "$PREFIX-*.gguf" | wc -l | tr -d ' ')
if [ "$got" != "$NSHARDS" ]; then
    printf 'expected %s shards, got %s -- adjust SPLIT_MAX_SIZE or NSHARDS\n' \
        "$NSHARDS" "$got" >&2
    exit 1
fi
_have_all || { printf 'shard naming is not %s-00001-of-%05d.gguf\n' "$PREFIX" "$NSHARDS" >&2; exit 1; }

printf '%s\n' "$WANT" > "$STAMP"
printf 'wrote %s shards to %s\n' "$got" "$SHARDS" >&2
printf '%s\n' "$SHARDS"
