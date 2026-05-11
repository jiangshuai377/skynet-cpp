#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BUILD_DIR=build-coverage
REPORT_DIR=coverage-report
THREAD_COUNT=8
UNIT_TIMEOUT=300

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-dir) BUILD_DIR=$2; shift 2 ;;
    --report-dir) REPORT_DIR=$2; shift 2 ;;
    --thread-count) THREAD_COUNT=$2; shift 2 ;;
    --unit-timeout-seconds) UNIT_TIMEOUT=$2; shift 2 ;;
    --gate|--stress-timeout-seconds|--stress-cpp-threshold|--stress-lua-threshold|--full-cpp-threshold|--full-lua-threshold)
      shift 2 ;;
    *) shift ;;
  esac
done

cd "$ROOT"
cmake -S . -B "$BUILD_DIR" -G Ninja -DCMAKE_C_COMPILER="${CC:-clang}" -DCMAKE_CXX_COMPILER="${CXX:-clang++}" -DCMAKE_BUILD_TYPE=Debug -DSKYNET_ENABLE_COVERAGE=ON
cmake --build "$BUILD_DIR" --config Debug --parallel
mkdir -p "$REPORT_DIR"
LLVM_PROFILE_FILE="$ROOT/$REPORT_DIR/skynet-unit-%p.profraw" "$ROOT/$BUILD_DIR/skynet-cpp-unit"
OUT="$ROOT/$REPORT_DIR/logic.out"
ERR="$ROOT/$REPORT_DIR/logic.err"
rm -f "$OUT" "$ERR"
SKYNET_PRELOAD=tests/logic/preload.lua SKYNET_THREAD="$THREAD_COUNT" "$ROOT/$BUILD_DIR/skynet-cpp" >"$OUT" 2>"$ERR" &
PID=$!
i=0
while [ "$i" -lt "$UNIT_TIMEOUT" ]; do
  sleep 1
  if grep -F "PASS: unit coverage suite completed" "$OUT" "$ERR" >/dev/null 2>&1; then
    kill "$PID" >/dev/null 2>&1 || true
    break
  fi
  i=$((i + 1))
done
cat "$OUT" "$ERR"
ls "$REPORT_DIR"/*.profraw >/dev/null 2>&1 || { echo "no coverage profiles generated" >&2; exit 1; }
llvm-profdata merge -sparse "$REPORT_DIR"/*.profraw -o "$REPORT_DIR/skynet.profdata"
llvm-cov report "$ROOT/$BUILD_DIR/skynet-cpp" -object="$ROOT/$BUILD_DIR/skynet-cpp-unit" -instr-profile="$REPORT_DIR/skynet.profdata" -ignore-filename-regex='.*3rdparty.*' "$ROOT/src"
echo "coverage smoke PASS"
