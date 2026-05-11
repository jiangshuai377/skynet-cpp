#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BUILD_CONFIG=Release
BUILD_DIR=build-package
INSTALL_DIR=dist/skynet-cpp
CLEAN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-config) BUILD_CONFIG=$2; shift 2 ;;
    --build-dir) BUILD_DIR=$2; shift 2 ;;
    --install-dir) INSTALL_DIR=$2; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) shift ;;
  esac
done

cd "$ROOT"
if [ "$CLEAN" = "1" ]; then
  rm -rf "$BUILD_DIR" "$INSTALL_DIR"
fi
cmake -S . -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_CONFIG"
cmake --build "$BUILD_DIR" --config "$BUILD_CONFIG" --parallel
cmake --install "$BUILD_DIR" --config "$BUILD_CONFIG" --prefix "$ROOT/$INSTALL_DIR"
echo "package PASS: $INSTALL_DIR"
