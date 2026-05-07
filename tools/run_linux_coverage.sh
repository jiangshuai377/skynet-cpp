#!/usr/bin/env bash
set -euo pipefail

THREAD_COUNT=16
GATE=Stress
STRESS_CPP_THRESHOLD=70
STRESS_LUA_THRESHOLD=30
STRESS_MODULE_THRESHOLD=90
FULL_CPP_THRESHOLD=90
FULL_LUA_THRESHOLD=90
STRESS_TIMEOUT_SECONDS=600
UNIT_TIMEOUT_SECONDS=300
BUILD_DIR=build-linux-coverage
REPORT_DIR=coverage-report-linux

while [[ $# -gt 0 ]]; do
    case "$1" in
        --thread-count) THREAD_COUNT="$2"; shift 2 ;;
        --gate) GATE="$2"; shift 2 ;;
        --stress-cpp-threshold) STRESS_CPP_THRESHOLD="$2"; shift 2 ;;
        --stress-lua-threshold) STRESS_LUA_THRESHOLD="$2"; shift 2 ;;
        --stress-module-threshold) STRESS_MODULE_THRESHOLD="$2"; shift 2 ;;
        --full-cpp-threshold) FULL_CPP_THRESHOLD="$2"; shift 2 ;;
        --full-lua-threshold) FULL_LUA_THRESHOLD="$2"; shift 2 ;;
        --stress-timeout-seconds) STRESS_TIMEOUT_SECONDS="$2"; shift 2 ;;
        --unit-timeout-seconds) UNIT_TIMEOUT_SECONDS="$2"; shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --report-dir) REPORT_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$GATE" in
    Stress|Full|Both|ReportOnly) ;;
    *) echo "Invalid --gate: $GATE" >&2; exit 2 ;;
esac

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required tool not found: $1" >&2
        exit 1
    fi
}

require_tool cmake
require_tool clang
require_tool clang++
require_tool llvm-cov
require_tool llvm-profdata
require_tool python3

REPO="$(pwd -P)"
BUILD_PATH="$REPO/$BUILD_DIR"
REPORT_PATH="$REPO/$REPORT_DIR"
LUA_COVERAGE_DIR="$REPORT_PATH/lua"

rm -rf "$BUILD_PATH"
mkdir -p "$REPORT_PATH" "$LUA_COVERAGE_DIR"
rm -f "$REPORT_PATH"/*.profraw "$REPORT_PATH"/*.profdata "$LUA_COVERAGE_DIR"/*.log

GENERATOR_ARGS=()
if command -v ninja >/dev/null 2>&1; then
    GENERATOR_ARGS=(-G Ninja)
fi

echo "+ cmake -S . -B $BUILD_PATH ${GENERATOR_ARGS[*]} -DCMAKE_BUILD_TYPE=Debug -DSKYNET_ENABLE_COVERAGE=ON"
cmake -S . -B "$BUILD_PATH" "${GENERATOR_ARGS[@]}" \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_BUILD_TYPE=Debug \
    -DSKYNET_ENABLE_COVERAGE=ON

echo "+ cmake --build $BUILD_PATH --parallel"
cmake --build "$BUILD_PATH" --parallel

EXE="$BUILD_PATH/skynet-cpp"
CPP_UNIT_EXE="$BUILD_PATH/skynet-cpp-unit"
if [[ ! -x "$EXE" ]]; then
    echo "Executable not found: $EXE" >&2
    exit 1
fi

export SKYNET_THREAD="$THREAD_COUNT"
export SKYNET_LUA_COVERAGE=1
export SKYNET_LUA_COVERAGE_DIR="$LUA_COVERAGE_DIR"
export LLVM_PROFILE_FILE="$REPORT_PATH/skynet-%p.profraw"
unset SKYNET_START || true

if [[ -x "$CPP_UNIT_EXE" ]]; then
    echo "+ $CPP_UNIT_EXE"
    "$CPP_UNIT_EXE"
fi

run_suite() {
    local preload="$1"
    local out="$2"
    local err="$3"
    local pass_pattern="$4"
    local timeout_seconds="$5"

    rm -f "$out" "$err"
    export SKYNET_PRELOAD="$preload"
    echo "+ SKYNET_PRELOAD=$preload timeout ${timeout_seconds}s $EXE"
    set +e
    timeout "${timeout_seconds}s" "$EXE" >"$out" 2>"$err"
    local code=$?
    set -e
    cat "$out" || true
    cat "$err" || true

    if grep -Eq "callback error|timed out|No dispatch function|Unknown message type|Unknown response session|CASE failed" "$out" "$err"; then
        echo "Suite failed: $preload" >&2
        exit 1
    fi
    if ! grep -q "$pass_pattern" "$out"; then
        echo "Suite did not report pass: $preload (exit $code)" >&2
        exit 1
    fi
}

run_suite "tests/stress/preload.lua" \
    "$REPORT_PATH/stress.out" "$REPORT_PATH/stress.err" \
    "PASS: stress suite completed" "$STRESS_TIMEOUT_SECONDS"

if [[ "$GATE" == "Full" || "$GATE" == "Both" || "$GATE" == "ReportOnly" ]]; then
    run_suite "tests/logic/preload.lua" \
        "$REPORT_PATH/unit.out" "$REPORT_PATH/unit.err" \
        "PASS: unit coverage suite completed" "$UNIT_TIMEOUT_SECONDS"
fi

mapfile -t PROFRAW < <(find "$REPORT_PATH" -maxdepth 1 -name '*.profraw' -type f | sort)
if [[ "${#PROFRAW[@]}" -eq 0 ]]; then
    echo "No LLVM profraw files generated" >&2
    exit 1
fi

PROFDATA="$REPORT_PATH/skynet.profdata"
echo "+ llvm-profdata merge -sparse ... -o $PROFDATA"
llvm-profdata merge -sparse "${PROFRAW[@]}" -o "$PROFDATA"

CPP_JSON="$REPORT_PATH/cpp-coverage.json"
EXPORT_ARGS=("$EXE")
SHOW_ARGS=("$EXE")
if [[ -x "$CPP_UNIT_EXE" ]]; then
    EXPORT_ARGS+=("-object=$CPP_UNIT_EXE")
    SHOW_ARGS+=("-object=$CPP_UNIT_EXE")
fi

echo "+ llvm-cov export"
llvm-cov export "${EXPORT_ARGS[@]}" "-instr-profile=$PROFDATA" -format=text \
    -ignore-filename-regex='.*3rdparty.*' "$REPO/src" > "$CPP_JSON"

HTML_DIR="$REPORT_PATH/cpp-html"
rm -rf "$HTML_DIR"
echo "+ llvm-cov show"
llvm-cov show "${SHOW_ARGS[@]}" "-instr-profile=$PROFDATA" -format=html \
    -ignore-filename-regex='.*3rdparty.*' "-output-dir=$HTML_DIR" "$REPO/src" >/dev/null

python3 - "$REPO" "$REPORT_PATH" "$GATE" \
    "$STRESS_CPP_THRESHOLD" "$STRESS_LUA_THRESHOLD" "$STRESS_MODULE_THRESHOLD" \
    "$FULL_CPP_THRESHOLD" "$FULL_LUA_THRESHOLD" <<'PY'
import json
import os
import re
import sys

repo, report, gate = sys.argv[1:4]
stress_cpp_threshold = float(sys.argv[4])
stress_lua_threshold = float(sys.argv[5])
stress_module_threshold = float(sys.argv[6])
full_cpp_threshold = float(sys.argv[7])
full_lua_threshold = float(sys.argv[8])
repo = os.path.realpath(repo).replace("\\", "/")
lua_cov_dir = os.path.join(report, "lua")

def relpath(path):
    return os.path.realpath(path).replace("\\", "/")[len(repo) + 1:]

def summary(rows):
    covered = sum(int(row["Covered"]) for row in rows)
    lines = sum(int(row["Lines"]) for row in rows)
    pct = round(100.0 * covered / lines, 2) if lines else 0.0
    return {"Covered": covered, "Lines": lines, "Percent": pct}

def save_rows(path, rows):
    rows = sorted(rows, key=lambda r: (r["Percent"], r["File"]))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=4)

def assert_cov(label, item, threshold):
    if item["Lines"] == 0:
        raise SystemExit(f"{label} coverage has no target lines")
    if item["Percent"] < threshold:
        raise SystemExit(f"{label} coverage {item['Percent']:.2f}% is below threshold {threshold:.2f}%")

with open(os.path.join(report, "cpp-coverage.json"), "r", encoding="utf-8") as f:
    cpp_cov = json.load(f)

cpp_rows = []
for file in cpp_cov["data"][0]["files"]:
    name = file["filename"].replace("\\", "/")
    if not name.startswith(repo + "/"):
        continue
    rel = name[len(repo) + 1:]
    if not rel.startswith("src/"):
        continue
    lines = int(file["summary"]["lines"]["count"])
    covered = int(file["summary"]["lines"]["covered"])
    pct = round(100.0 * covered / lines, 2) if lines else 100.0
    cpp_rows.append({"File": rel, "Covered": covered, "Lines": lines, "Percent": pct})

def stress_lua_targets():
    paths = [
        "lualib/bson.lua",
        "lualib/sharedata.lua",
        "lualib/skynet/cluster.lua",
        "lualib/skynet.lua",
        "lualib/skynet/coverage.lua",
        "lualib/skynet/crypt.lua",
        "lualib/skynet/db/mongo.lua",
        "lualib/skynet/db/mysql.lua",
        "lualib/skynet/db/redis.lua",
        "lualib/skynet/debug.lua",
        "lualib/skynet/multicast.lua",
        "lualib/skynet/socketchannel.lua",
        "lualib/socket.lua",
        "service/clusterd.lua",
        "service/clustersender.lua",
        "service/debug_console.lua",
        "service/launcher.lua",
        "service/multicastd.lua",
        "service/sharedatad.lua",
    ]
    return [os.path.join(repo, p).replace("\\", "/") for p in paths if os.path.exists(os.path.join(repo, p))]

def full_lua_targets():
    excluded = {
        "lualib/loader.lua",
        "lualib/skynet/coverage.lua",
        "service/clusteragent.lua",
        "examples/main.lua",
    }
    files = []
    for root, _, names in os.walk(os.path.join(repo, "lualib")):
        for name in names:
            if name.endswith(".lua"):
                path = os.path.join(root, name)
                if relpath(path) not in excluded:
                    files.append(os.path.realpath(path).replace("\\", "/"))
    service_dir = os.path.join(repo, "service")
    for name in os.listdir(service_dir):
        path = os.path.join(service_dir, name)
        if name.endswith(".lua") and os.path.isfile(path) and not name.startswith("test_"):
            if relpath(path) not in excluded:
                files.append(os.path.realpath(path).replace("\\", "/"))
    return sorted(set(files))

def executable_line(line):
    trim = line.strip()
    if not trim or trim.startswith("--"):
        return False
    if re.match(r"^(local\s+)?function\b", trim):
        return False
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*=\s*function\b", trim):
        return False
    if re.match(r"^\[[^\]]+\]\s*=\s*function\b", trim):
        return False
    if re.match(r"^end[,]?$", trim):
        return False
    if trim == "else":
        return False
    if re.match(r"^\}?\)?[,]?$", trim):
        return False
    if re.match(r"^[{}(),]+$", trim):
        return False
    return True

def hit_set(target_files):
    targets = {os.path.realpath(p).replace("\\", "/") for p in target_files}
    hits = set()
    if not os.path.isdir(lua_cov_dir):
        return hits
    for name in os.listdir(lua_cov_dir):
        if not name.endswith(".log"):
            continue
        with open(os.path.join(lua_cov_dir, name), "r", encoding="utf-8", errors="ignore") as f:
            for raw in f:
                line = raw.strip()
                m = re.match(r"^(.*):([0-9]+)$", line)
                if not m:
                    continue
                path = os.path.realpath(m.group(1)).replace("\\", "/")
                if path in targets:
                    hits.add((path, int(m.group(2))))
    return hits

def lua_rows(target_files):
    hits = hit_set(target_files)
    rows = []
    for path in target_files:
        path = os.path.realpath(path).replace("\\", "/")
        count = 0
        covered = 0
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for idx, line in enumerate(f, start=1):
                if not executable_line(line):
                    continue
                count += 1
                if (path, idx) in hits:
                    covered += 1
        pct = round(100.0 * covered / count, 2) if count else 100.0
        rows.append({"File": path[len(repo) + 1:], "Covered": covered, "Lines": count, "Percent": pct})
    return rows

stress_cpp_rows = cpp_rows
full_cpp_rows = cpp_rows
stress_lua_rows = lua_rows(stress_lua_targets())
full_lua_rows = lua_rows(full_lua_targets())

groups = {
    "cluster": ["lualib/skynet/cluster.lua", "service/clusterd.lua", "service/clustersender.lua"],
    "socketchannel": ["lualib/skynet/socketchannel.lua"],
    "debug_console": ["service/debug_console.lua"],
    "db": ["lualib/skynet/db/redis.lua", "lualib/skynet/db/mysql.lua", "lualib/skynet/db/mongo.lua"],
}

stress_modules = {}
for name, rels in groups.items():
    selected = [row for row in stress_lua_rows if row["File"] in set(rels)]
    stress_modules[name] = summary(selected)

save_rows(os.path.join(report, "cpp-stress-coverage.json"), stress_cpp_rows)
save_rows(os.path.join(report, "lua-stress-coverage.json"), stress_lua_rows)
save_rows(os.path.join(report, "cpp-full-coverage.json"), full_cpp_rows)
save_rows(os.path.join(report, "lua-full-coverage.json"), full_lua_rows)

stress_cpp = summary(stress_cpp_rows)
stress_lua = summary(stress_lua_rows)
full_cpp = summary(full_cpp_rows)
full_lua = summary(full_lua_rows)
result = {
    "Gate": gate,
    "Stress": {
        "Cpp": stress_cpp,
        "Lua": stress_lua,
        "Modules": stress_modules,
        "CppThreshold": stress_cpp_threshold,
        "LuaThreshold": stress_lua_threshold,
        "ModuleThreshold": stress_module_threshold,
    },
    "Full": {
        "Cpp": full_cpp,
        "Lua": full_lua,
        "CppThreshold": full_cpp_threshold,
        "LuaThreshold": full_lua_threshold,
    },
    "Reports": {
        "CppHtml": os.path.join(report, "cpp-html/index.html"),
        "CppStressJson": os.path.join(report, "cpp-stress-coverage.json"),
        "LuaStressJson": os.path.join(report, "lua-stress-coverage.json"),
        "CppFullJson": os.path.join(report, "cpp-full-coverage.json"),
        "LuaFullJson": os.path.join(report, "lua-full-coverage.json"),
    }
}
with open(os.path.join(report, "coverage-summary.json"), "w", encoding="utf-8") as f:
    json.dump(result, f, indent=4)

print(f"Stress C++ line coverage: {stress_cpp['Percent']:.2f}% ({stress_cpp['Covered']}/{stress_cpp['Lines']}), threshold {stress_cpp_threshold:.2f}%")
print(f"Stress Lua line coverage: {stress_lua['Percent']:.2f}% ({stress_lua['Covered']}/{stress_lua['Lines']}), threshold {stress_lua_threshold:.2f}%")
print(f"Full C++ line coverage: {full_cpp['Percent']:.2f}% ({full_cpp['Covered']}/{full_cpp['Lines']}), threshold {full_cpp_threshold:.2f}%")
print(f"Full Lua line coverage: {full_lua['Percent']:.2f}% ({full_lua['Covered']}/{full_lua['Lines']}), threshold {full_lua_threshold:.2f}%")
for name, item in stress_modules.items():
    print(f"Stress module {name} line coverage: {item['Percent']:.2f}% ({item['Covered']}/{item['Lines']}), threshold {stress_module_threshold:.2f}%")
print(f"Coverage gate: {gate}")
print(f"C++ HTML report: {os.path.join(report, 'cpp-html/index.html')}")
print(f"Coverage summary: {os.path.join(report, 'coverage-summary.json')}")

if gate in ("Stress", "Both"):
    assert_cov("Stress C++", stress_cpp, stress_cpp_threshold)
    assert_cov("Stress Lua", stress_lua, stress_lua_threshold)
    for name, item in stress_modules.items():
        assert_cov(f"Stress module {name}", item, stress_module_threshold)
if gate in ("Full", "Both"):
    assert_cov("Full C++", full_cpp, full_cpp_threshold)
    assert_cov("Full Lua", full_lua, full_lua_threshold)
PY
