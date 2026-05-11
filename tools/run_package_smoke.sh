#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
INSTALL_DIR=dist/skynet-cpp
THREAD=4
TIMEOUT_SECONDS=20

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-dir) INSTALL_DIR=$2; shift 2 ;;
    --thread) THREAD=$2; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS=$2; shift 2 ;;
    *) shift ;;
  esac
done

cd "$ROOT"
EXE="$ROOT/$INSTALL_DIR/bin/skynet-cpp"
[ -x "$EXE" ] || EXE="$ROOT/$INSTALL_DIR/bin/skynet-cpp.exe"
[ -x "$EXE" ] || { echo "package executable not found under $INSTALL_DIR/bin" >&2; exit 1; }
mkdir -p package-results
OUT="$ROOT/package-results/package-smoke.out"
ERR="$ROOT/package-results/package-smoke.err"
rm -f "$OUT" "$ERR"
(cd "$ROOT/$INSTALL_DIR" && SKYNET_THREAD="$THREAD" SKYNET_PRELOAD=examples/preload.lua "$EXE" >"$OUT" 2>"$ERR") &
PID=$!
i=0
while [ "$i" -lt "$TIMEOUT_SECONDS" ]; do
  sleep 1
  if grep -F "[main] === Example completed ===" "$OUT" "$ERR" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    cat "$OUT" "$ERR"
    echo "package smoke PASS"
    exit 0
  fi
  i=$((i + 1))
done
kill "$PID" >/dev/null 2>&1 || true
cat "$OUT" "$ERR"
echo "package smoke timed out" >&2
exit 1
