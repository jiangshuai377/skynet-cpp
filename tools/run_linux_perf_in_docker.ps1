param(
    [string]$Label = "linux-perf",
    [string[]]$ThreadCounts = @("8", "16", "32"),
    [int]$Iterations = 5,
    [int]$TimeoutSeconds = 600,
    [switch]$SkipNative
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path ".").Path
$root = (Resolve-Path "..").Path
$normalizedThreadCounts = @()
foreach ($item in $ThreadCounts) {
    foreach ($part in ([string]$item -split ",")) {
        $part = $part.Trim()
        if ($part -ne "") {
            $normalizedThreadCounts += [int]$part
        }
    }
}
if ($normalizedThreadCounts.Count -eq 0) {
    throw "ThreadCounts cannot be empty"
}
$threads = ($normalizedThreadCounts -join " ")
$skipNativeValue = if ($SkipNative) { "1" } else { "0" }

$script = @'
set -euo pipefail

LABEL="__LABEL__"
THREADS="__THREADS__"
ITERATIONS="__ITERATIONS__"
TIMEOUT_SECONDS="__TIMEOUT_SECONDS__"
SKIP_NATIVE="__SKIP_NATIVE__"

cd /work/skynet-cpp
mkdir -p perf-results/logs

apt-get update >/dev/null
apt-get install -y --no-install-recommends build-essential cmake ninja-build ca-certificates >/dev/null

cmake -S . -B build-linux-perf -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-linux-perf --parallel

if [ "$SKIP_NATIVE" != "1" ]; then
  cd /work/resource/skynet
  if [ -x 3rd/jemalloc/autogen.sh ] || [ -f 3rd/jemalloc/Makefile ]; then
    make linux
    echo "native_jemalloc=on" >/work/skynet-cpp/perf-results/${LABEL}-native-build.txt
  else
    make linux MALLOC_STATICLIB= SKYNET_DEFINES=-DNOUSE_JEMALLOC
    echo "native_jemalloc=off" >/work/skynet-cpp/perf-results/${LABEL}-native-build.txt
  fi
fi

make_native_config() {
  local threads="$1"
  cat >/tmp/native_perf_config <<EOF
root = "./"
luaservice = root.."service/?.lua;"..root.."test/?.lua;"..root.."examples/?.lua;"..root.."test/?/init.lua"
lualoader = root .. "lualib/loader.lua"
lua_path = root.."lualib/?.lua;"..root.."lualib/?/init.lua"
lua_cpath = root .. "luaclib/?.so"
snax = root.."examples/?.lua;"..root.."test/?.lua"
thread = ${threads}
logger = nil
logpath = "."
harbor = 0
start = "perf_main"
bootstrap = "snlua bootstrap"
cpath = root.."cservice/?.so"
EOF
}

run_cpp() {
  local profile="$1" cases="$2" workers="$3" calls="$4" fire="$5" lifecycle="$6" clients="$7" messages="$8" threads="$9" iter="${10}"
  local port=$((25000 + threads * 100 + iter))
  local log="/work/skynet-cpp/perf-results/logs/${LABEL}-cpp-${profile}-t${threads}-i${iter}.out"
  echo "cpp $profile threads=$threads iteration=$iter"
  cd /work/skynet-cpp
  SKYNET_PRELOAD="tests/perf/preload.lua" SKYNET_THREAD="$threads" \
    SKYNET_PERF_CASES="$cases" SKYNET_PERF_WORKERS="$workers" \
    SKYNET_PERF_CALLS="$calls" SKYNET_PERF_FIRE="$fire" \
    SKYNET_PERF_LIFECYCLE="$lifecycle" SKYNET_PERF_SOCKET_CLIENTS="$clients" \
    SKYNET_PERF_SOCKET_MESSAGES="$messages" SKYNET_PERF_SOCKET_PORT="$port" \
    timeout "$TIMEOUT_SECONDS" ./build-linux-perf/skynet-cpp >"$log" 2>&1
  grep -q "\[perf\] PASS: perf suite completed" "$log"
}

run_native() {
  local profile="$1" cases="$2" workers="$3" calls="$4" fire="$5" lifecycle="$6" clients="$7" messages="$8" threads="$9" iter="${10}"
  [ "$SKIP_NATIVE" = "1" ] && return 0
  local port=$((26000 + threads * 100 + iter))
  local log="/work/skynet-cpp/perf-results/logs/${LABEL}-native-${profile}-t${threads}-i${iter}.out"
  echo "native $profile threads=$threads iteration=$iter"
  cd /work/resource/skynet
  make_native_config "$threads"
  SKYNET_PERF_CASES="$cases" SKYNET_PERF_WORKERS="$workers" \
    SKYNET_PERF_CALLS="$calls" SKYNET_PERF_FIRE="$fire" \
    SKYNET_PERF_LIFECYCLE="$lifecycle" SKYNET_PERF_SOCKET_CLIENTS="$clients" \
    SKYNET_PERF_SOCKET_MESSAGES="$messages" SKYNET_PERF_SOCKET_PORT="$port" \
    timeout "$TIMEOUT_SECONDS" ./skynet /tmp/native_perf_config >"$log" 2>&1 || true
}

run_profile_pair() {
  local profile="$1" cases="$2" workers="$3" calls="$4" fire="$5" lifecycle="$6" clients="$7" messages="$8" threads="$9" iter="${10}"
  run_cpp "$profile" "$cases" "$workers" "$calls" "$fire" "$lifecycle" "$clients" "$messages" "$threads" "$iter"
  run_native "$profile" "$cases" "$workers" "$calls" "$fire" "$lifecycle" "$clients" "$messages" "$threads" "$iter"
}

for threads in $THREADS; do
  for iter in $(seq 1 "$ITERATIONS"); do
    run_profile_pair actor-heavy actor 64 1000 2000 100 32 50 "$threads" "$iter"
    run_profile_pair scheduler-heavy scheduler 128 200 400 100 32 50 "$threads" "$iter"
    run_profile_pair socket-heavy socket 32 100 100 100 128 200 "$threads" "$iter"
    run_profile_pair socket-heavy-256 socket 32 100 100 100 256 200 "$threads" "$iter"
    run_profile_pair mixed-full mixed 64 500 1000 500 128 100 "$threads" "$iter"
    run_cpp lifecycle-heavy lifecycle 32 100 100 1000 32 50 "$threads" "$iter"
  done
done
'@

$script = $script.Replace("__LABEL__", $Label)
$script = $script.Replace("__THREADS__", $threads)
$script = $script.Replace("__ITERATIONS__", [string]$Iterations)
$script = $script.Replace("__TIMEOUT_SECONDS__", [string]$TimeoutSeconds)
$script = $script.Replace("__SKIP_NATIVE__", $skipNativeValue)

New-Item -ItemType Directory -Force (Join-Path $repo "perf-results") | Out-Null
$scriptPath = Join-Path $repo "perf-results/$Label-run.sh"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($scriptPath, ($script -replace "`r`n", "`n"), $utf8NoBom)
$containerScript = "/work/skynet-cpp/perf-results/$Label-run.sh"

docker run --rm -v "$root`:/work" -w /work/skynet-cpp debian:bookworm bash $containerScript
if ($LASTEXITCODE -ne 0) {
    throw "linux perf docker run failed"
}

Write-Host "Linux perf logs written under perf-results/logs with label $Label"
