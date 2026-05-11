#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
MODE=Quick
BUILD_DIR=build
LOGIC_TIMEOUT=300
STRESS_TIMEOUT=600

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) MODE=$2; shift 2 ;;
    --build-dir) BUILD_DIR=$2; shift 2 ;;
    --logic-timeout-seconds) LOGIC_TIMEOUT=$2; shift 2 ;;
    --stress-timeout-seconds) STRESS_TIMEOUT=$2; shift 2 ;;
    *) shift ;;
  esac
done

cd "$ROOT"

build() {
  cmake -S . -B "$1" -DCMAKE_BUILD_TYPE="$2"
  cmake --build "$1" --config "$2" --parallel
}

resolve_exe() {
  if [ -x "$1/$2/skynet-cpp" ]; then echo "$1/$2/skynet-cpp"; return 0; fi
  if [ -x "$1/skynet-cpp" ]; then echo "$1/skynet-cpp"; return 0; fi
  if [ -x "$1/$2/skynet-cpp.exe" ]; then echo "$1/$2/skynet-cpp.exe"; return 0; fi
  if [ -x "$1/skynet-cpp.exe" ]; then echo "$1/skynet-cpp.exe"; return 0; fi
  echo "skynet-cpp executable not found under $1" >&2
  return 1
}

run_until_pass() {
  exe=$1
  preload=$2
  pass=$3
  timeout_seconds=$4
  label=$5
  mkdir -p verify-results
  out="verify-results/$label.out"
  err="verify-results/$label.err"
  rm -f "$out" "$err"
  SKYNET_PRELOAD=$preload SKYNET_THREAD=8 "$exe" >"$out" 2>"$err" &
  pid=$!
  i=0
  while [ "$i" -lt "$timeout_seconds" ]; do
    sleep 1
    if grep -F "$pass" "$out" "$err" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      cat "$out" "$err"
      return 0
    fi
    if grep -Ei "callback error|timed out|No dispatch function|Unknown response session|CASE failed|lost response" "$out" "$err" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      cat "$out" "$err"
      echo "$label failed" >&2
      return 1
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
  done
  kill "$pid" >/dev/null 2>&1 || true
  cat "$out" "$err"
  echo "$label timed out" >&2
  return 1
}

build "$BUILD_DIR" Debug
EXE=$(resolve_exe "$BUILD_DIR" Debug)
run_until_pass "$EXE" tests/logic/preload.lua "PASS: unit coverage suite completed" "$LOGIC_TIMEOUT" logic-debug

if [ "$MODE" = "Full" ]; then
  run_until_pass "$EXE" tests/stress/preload.lua "PASS: stress suite completed" "$STRESS_TIMEOUT" stress-debug
fi

build "$BUILD_DIR-release" Release
echo "verify $MODE PASS"
