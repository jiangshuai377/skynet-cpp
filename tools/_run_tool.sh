#!/usr/bin/env sh
set -eu

TOOLS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

die() {
  echo "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "sha256sum or shasum is required to verify vendored Python archives"
  fi
}

bootstrap_python() {
  [ -f "$ARCHIVE" ] || die "Python archive not found: $ARCHIVE
Run git lfs pull, or set SKYNET_TOOLS_PYTHON to an existing Python."

  if head -n 1 "$ARCHIVE" | grep -q '^version https://git-lfs.github.com/spec/v1'; then
    die "Python archive is still a Git LFS pointer: $ARCHIVE
Run git lfs pull before using offline tools."
  fi

  command -v tar >/dev/null 2>&1 || die "tar was not found on PATH; cannot extract vendored Python archive"

  ACTUAL_SHA256=$(sha256_file "$ARCHIVE")
  [ "$ACTUAL_SHA256" = "$ARCHIVE_SHA256" ] || die "Python archive SHA256 mismatch: $ARCHIVE
Expected: $ARCHIVE_SHA256
Actual:   $ACTUAL_SHA256"

  CACHE_ROOT="$TOOLS_DIR/python/cache"
  RUNTIME_ROOT="$TOOLS_DIR/python/runtime"
  mkdir -p "$CACHE_ROOT" "$RUNTIME_ROOT"
  TMP_DIR=$(mktemp -d "$CACHE_ROOT/$PLATFORM.XXXXXX")

  echo "Extracting vendored Python runtime for $PLATFORM..."
  if ! tar -xzf "$ARCHIVE" -C "$TMP_DIR" --strip-components=1; then
    rm -rf "$TMP_DIR"
    die "Failed to extract Python archive: $ARCHIVE"
  fi

  rm -rf "$RUNTIME_DIR"
  mv "$TMP_DIR" "$RUNTIME_DIR"
  chmod +x "$PY" 2>/dev/null || true
}

if [ "${SKYNET_TOOLS_PYTHON:-}" ]; then
  PY=$SKYNET_TOOLS_PYTHON
else
  OS=$(uname -s)
  ARCH=$(uname -m)
  case "$OS:$ARCH" in
    Linux:x86_64)
      PLATFORM=linux-x86_64
      ARCHIVE_NAME=cpython-3.13.13+20260414-x86_64-unknown-linux-gnu-install_only.tar.gz
      ARCHIVE_SHA256=e5ec3b2c5693215d153c434ac018e75511b2c4f96d2bce30468a477cb3a89d5e
      PY_REL=bin/python3
      ;;
    Darwin:x86_64)
      PLATFORM=macos-x86_64
      ARCHIVE_NAME=cpython-3.13.13+20260414-x86_64-apple-darwin-install_only.tar.gz
      ARCHIVE_SHA256=540337412d2c4220e99280f741dbf45c1e3da3a39edaaab20c6ba1d53e1692ef
      PY_REL=bin/python3
      ;;
    Darwin:arm64|Darwin:aarch64)
      PLATFORM=macos-aarch64
      ARCHIVE_NAME=cpython-3.13.13+20260414-aarch64-apple-darwin-install_only.tar.gz
      ARCHIVE_SHA256=c652dad552122cd2e76968ec41c803f8222038169b11310dba0c85928265f5c1
      PY_REL=bin/python3
      ;;
    *) die "Unsupported tools platform: $OS $ARCH" ;;
  esac
  ARCHIVE="$TOOLS_DIR/python/archives/$ARCHIVE_NAME"
  RUNTIME_DIR="$TOOLS_DIR/python/runtime/$PLATFORM"
  PY="$RUNTIME_DIR/$PY_REL"
  [ -x "$PY" ] || bootstrap_python
fi

if [ ! -x "$PY" ]; then
  die "Python runtime not found or not executable: $PY
Set SKYNET_TOOLS_PYTHON for local debugging."
fi

if [ "${PYTHONPATH:-}" ]; then
  export PYTHONPATH="$TOOLS_DIR/py:$PYTHONPATH"
else
  export PYTHONPATH="$TOOLS_DIR/py"
fi

exec "$PY" -m skynet_tools "$@"
