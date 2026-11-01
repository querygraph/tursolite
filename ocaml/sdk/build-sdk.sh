#!/bin/sh
# Provides libturso_sdk_kit with the versions in Cargo.lock. The target directory
# lives outside dune's sandbox so that a rebuild is incremental. opam's own
# sandbox allows no cargo at all: run `make sdk` first, and a library stamped
# with this Cargo.lock is copied here without building.
# build-sdk.sh --cache-only builds and stamps, and copies nothing.
set -e
here=$PWD
target=${FIRSTPAIR_TURSOLITE_TARGET:-$HOME/.cache/firstpair-tursolite/target}
stamp=$target/release/firstpair-tursolite.lock
cd ../..
if ! cmp -s Cargo.lock "$stamp"; then
  CARGO_TARGET_DIR=$target cargo build --locked --release -p turso_sdk_kit -j "${CARGO_JOBS:-8}" >&2
  cp Cargo.lock "$stamp"
fi
[ "$1" = --cache-only ] && exit 0
cp "$target/release/libturso_sdk_kit.a" "$here/libturso_sdk_kit.a"
cp "$target/release/libturso_sdk_kit.dylib" "$here/dllturso_sdk_kit.so" 2>/dev/null ||
  cp "$target/release/libturso_sdk_kit.so" "$here/dllturso_sdk_kit.so"
