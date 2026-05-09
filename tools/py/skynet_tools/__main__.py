from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / "tools"
VS_CMAKE = Path(
    r"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
)
VS_NINJA = Path(
    r"C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
)
FAIL_PATTERN = re.compile(
    r"callback error|timed out|No dispatch function|Unknown message type|Unknown response session|CASE failed|lost response",
    re.IGNORECASE,
)


def norm(path: os.PathLike[str] | str) -> str:
    return str(Path(path).resolve()).replace("\\", "/")


def rel(path: os.PathLike[str] | str) -> str:
    return norm(path)[len(norm(ROOT)) + 1 :]


def info(message: str) -> None:
    print(message, flush=True)


def fail(message: str) -> None:
    raise RuntimeError(message)


def find_tool(name: str, fallback: Path | None = None) -> str:
    found = shutil.which(name)
    if found:
        return found
    if fallback and fallback.exists():
        return str(fallback)
    fail(f"Required tool not found: {name}")


def find_cmake() -> str:
    return find_tool("cmake", VS_CMAKE if platform.system() == "Windows" else None)


def find_ninja() -> str | None:
    found = shutil.which("ninja")
    if found:
        return found
    if platform.system() == "Windows" and VS_NINJA.exists():
        return str(VS_NINJA)
    return None


def find_mt() -> str:
    found = shutil.which("mt")
    if found:
        return found
    kits = Path(r"C:\Program Files (x86)\Windows Kits\10\bin")
    if kits.exists():
        matches = sorted(kits.rglob("x64/mt.exe"), reverse=True)
        if matches:
            return str(matches[0])
    fail("Required tool not found: mt.exe")


def run_checked(argv: list[str | os.PathLike[str]], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> None:
    cmd = [str(x) for x in argv]
    info("+ " + " ".join(cmd))
    completed = subprocess.run(cmd, cwd=str(cwd), env=env)
    if completed.returncode != 0:
        fail("Command failed: " + " ".join(cmd))


def run_capture(argv: list[str | os.PathLike[str]], *, cwd: Path = ROOT, env: dict[str, str] | None = None) -> str:
    cmd = [str(x) for x in argv]
    info("+ " + " ".join(cmd))
    completed = subprocess.run(cmd, cwd=str(cwd), env=env, text=True, capture_output=True)
    if completed.returncode != 0:
        if completed.stdout:
            print(completed.stdout, end="")
        if completed.stderr:
            print(completed.stderr, end="", file=sys.stderr)
        fail("Command failed: " + " ".join(cmd))
    return completed.stdout


def remove_tree(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def safe_read(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="ignore")


def print_file(path: Path) -> None:
    text = safe_read(path)
    if text:
        print(text, end="" if text.endswith("\n") else "\n")


def resolve_exe(build_dir: Path, config: str) -> Path | None:
    candidates = [
        build_dir / config / "skynet-cpp.exe",
        build_dir / "skynet-cpp.exe",
        build_dir / "skynet-cpp",
    ]
    return next((p for p in candidates if p.exists()), None)


def run_until_pass(
    exe: Path,
    *,
    preload: str,
    pass_pattern: str,
    timeout_seconds: int,
    label: str,
    out: Path,
    err: Path,
    thread: int = 8,
    env_extra: dict[str, str] | None = None,
    cwd: Path = ROOT,
    wait_on_pass: bool = False,
    grace_seconds: int = 30,
) -> None:
    ensure_dir(out.parent)
    for path in (out, err):
        if path.exists():
            path.unlink()

    env = os.environ.copy()
    env["SKYNET_PRELOAD"] = preload
    env["SKYNET_THREAD"] = str(thread)
    env.pop("SKYNET_START", None)
    if env_extra:
        env.update({k: str(v) for k, v in env_extra.items()})

    with out.open("wb") as stdout, err.open("wb") as stderr:
        proc = subprocess.Popen([str(exe)], cwd=str(cwd), env=env, stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + timeout_seconds
        state = "TIMEOUT"
        while time.monotonic() < deadline:
            time.sleep(0.25)
            combined = safe_read(out) + "\n" + safe_read(err)
            if re.search(pass_pattern, combined):
                state = "PASS"
                break
            if FAIL_PATTERN.search(combined):
                state = "FAIL"
                break
            code = proc.poll()
            if code is not None:
                state = f"EXIT {code}"
                break

        if state == "PASS" and wait_on_pass:
            try:
                proc.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                proc.kill()
                fail(f"{label} passed but did not exit within {grace_seconds} seconds")
        elif proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    print_file(out)
    print_file(err)
    if state != "PASS":
        fail(f"{label} failed: {state}")


def configure_build(build_dir: Path, build_type: str, *, coverage: bool = False) -> None:
    cmake = find_cmake()
    args = [cmake, "-S", ".", "-B", build_dir, f"-DCMAKE_BUILD_TYPE={build_type}"]
    if coverage:
        if platform.system() == "Windows":
            clangcl = find_tool("clang-cl")
            mt = find_mt()
            ninja = find_ninja()
            if ninja:
                args = [
                    cmake,
                    "-S",
                    ".",
                    "-B",
                    build_dir,
                    "-G",
                    "Ninja",
                    f"-DCMAKE_C_COMPILER={clangcl}",
                    f"-DCMAKE_CXX_COMPILER={clangcl}",
                    f"-DCMAKE_MAKE_PROGRAM={ninja}",
                    f"-DCMAKE_MT={mt}",
                    "-DCMAKE_BUILD_TYPE=Debug",
                    "-DSKYNET_ENABLE_COVERAGE=ON",
                ]
            else:
                args = [
                    cmake,
                    "-S",
                    ".",
                    "-B",
                    build_dir,
                    "-G",
                    "Visual Studio 17 2022",
                    "-T",
                    "ClangCL",
                    "-DSKYNET_ENABLE_COVERAGE=ON",
                ]
        else:
            find_tool("clang")
            find_tool("clang++")
            generator = []
            ninja = find_ninja()
            if ninja:
                generator = ["-G", "Ninja"]
            args = [
                cmake,
                "-S",
                ".",
                "-B",
                build_dir,
                *generator,
                "-DCMAKE_C_COMPILER=clang",
                "-DCMAKE_CXX_COMPILER=clang++",
                "-DCMAKE_BUILD_TYPE=Debug",
                "-DSKYNET_ENABLE_COVERAGE=ON",
            ]
    run_checked([str(a) for a in args])


def build(build_dir: Path, config: str) -> None:
    run_checked([find_cmake(), "--build", build_dir, "--config", config, "--parallel"])


def cmd_verify(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    build_dir = ROOT / args.build_dir
    configure_build(build_dir, "Debug")
    build(build_dir, "Debug")
    debug_exe = resolve_exe(build_dir, "Debug")
    if not debug_exe:
        fail("Debug skynet-cpp executable not found")
    run_until_pass(
        debug_exe,
        preload="tests/logic/preload.lua",
        pass_pattern=r"PASS: unit coverage suite completed",
        timeout_seconds=args.logic_timeout_seconds,
        label="logic-debug",
        out=ROOT / "verify-results/logic-debug.out",
        err=ROOT / "verify-results/logic-debug.err",
    )

    release_dir = ROOT / f"{args.build_dir}-release"
    configure_build(release_dir, "Release")
    build(release_dir, "Release")
    release_exe = resolve_exe(release_dir, "Release")
    if not release_exe:
        fail("Release skynet-cpp executable not found")

    if args.mode == "Full":
        run_until_pass(
            debug_exe,
            preload="tests/stress/preload.lua",
            pass_pattern=r"PASS: stress suite completed",
            timeout_seconds=args.stress_timeout_seconds,
            label="stress-debug",
            out=ROOT / "verify-results/stress-debug.out",
            err=ROOT / "verify-results/stress-debug.err",
        )
        cmd_package(SimpleNamespace(build_config="Release", build_dir="build-package", install_dir="dist/skynet-cpp", clean=False))
        cmd_package_smoke(SimpleNamespace(install_dir="dist/skynet-cpp", thread=4, timeout_seconds=20))
        cmd_perf(
            SimpleNamespace(
                label="verify-smoke",
                mode="Manual",
                thread_counts=["8"],
                iterations=2,
                timeout_seconds=600,
                build_dir=f"{args.build_dir}-release",
                no_build=True,
            )
        )
        cmd_coverage(
            SimpleNamespace(
                thread_count=16,
                gate="ReportOnly",
                stress_cpp_threshold=0.0,
                stress_lua_threshold=0.0,
                stress_module_threshold=0.0,
                full_cpp_threshold=0.0,
                full_lua_threshold=0.0,
                cpp_threshold=-1.0,
                lua_threshold=-1.0,
                stress_timeout_seconds=600,
                unit_timeout_seconds=300,
                build_dir="build-coverage",
                report_dir="coverage-report",
            )
        )

    info(f"verify {args.mode} PASS")


def cmd_package(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    build_path = ROOT / args.build_dir
    install_path = ROOT / args.install_dir
    if args.clean:
        remove_tree(build_path)
        remove_tree(install_path)

    if not (build_path / "CMakeCache.txt").exists():
        configure_build(build_path, args.build_config)
    build(build_path, args.build_config)
    remove_tree(install_path)
    run_checked([find_cmake(), "--install", build_path, "--config", args.build_config, "--prefix", install_path])

    summary = {
        "BuildConfig": args.build_config,
        "BuildDir": norm(build_path),
        "InstallDir": norm(install_path),
        "Layout": ["bin", "lualib", "service", "examples", "doc"],
    }
    ensure_dir(ROOT / "package-results")
    (ROOT / "package-results/package-summary.json").write_text(json.dumps(summary, indent=4), encoding="utf-8")
    print(json.dumps(summary, indent=4))


def cmd_package_smoke(args: argparse.Namespace) -> None:
    root = (ROOT / args.install_dir).resolve()
    candidates = [root / "bin/skynet-cpp.exe", root / "bin/skynet-cpp"]
    exe = next((p for p in candidates if p.exists()), None)
    if not exe:
        fail(f"Installed skynet-cpp executable not found under {root}")
    run_until_pass(
        exe,
        preload="examples/preload.lua",
        pass_pattern=r"PASS: launcher LAUNCH works",
        timeout_seconds=args.timeout_seconds,
        label="package-smoke",
        out=ROOT / "package-results/package-smoke.out",
        err=ROOT / "package-results/package-smoke.err",
        thread=args.thread,
        cwd=root,
    )


def normalize_thread_counts(values: list[str]) -> list[int]:
    out: list[int] = []
    for item in values:
        for part in str(item).split(","):
            part = part.strip()
            if part:
                out.append(int(part))
    if not out:
        fail("ThreadCounts cannot be empty")
    return out


def percentile(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    sorted_values = sorted(values)
    idx = math.ceil((p / 100.0) * len(sorted_values)) - 1
    idx = max(0, min(idx, len(sorted_values) - 1))
    return float(sorted_values[idx])


def stats(values: list[float]) -> dict[str, float]:
    if not values:
        return {"min": 0.0, "median": 0.0, "p95": 0.0, "max": 0.0}
    sorted_values = sorted(values)
    return {
        "min": float(sorted_values[0]),
        "median": percentile(sorted_values, 50),
        "p95": percentile(sorted_values, 95),
        "max": float(sorted_values[-1]),
    }


def read_metrics(path: Path) -> dict[str, float]:
    text = safe_read(path)
    metrics: dict[str, float] = {}
    for match in re.finditer(r"\[perf\] METRIC case=([^ ]+) name=([^ ]+) value=([0-9.]+)", text):
        metrics[f"{match.group(1)}.{match.group(2)}"] = float(match.group(3))
    return metrics


PERF_PROFILES = [
    {"Name": "actor-heavy", "Cases": "actor", "Workers": 64, "Calls": 1000, "Fire": 2000, "Lifecycle": 100, "SocketClients": 32, "SocketMessages": 50},
    {"Name": "scheduler-heavy", "Cases": "scheduler", "Workers": 128, "Calls": 200, "Fire": 400, "Lifecycle": 100, "SocketClients": 32, "SocketMessages": 50},
    {"Name": "lifecycle-heavy", "Cases": "lifecycle", "Workers": 32, "Calls": 100, "Fire": 100, "Lifecycle": 1000, "SocketClients": 32, "SocketMessages": 50},
    {"Name": "socket-heavy", "Cases": "socket", "Workers": 32, "Calls": 100, "Fire": 100, "Lifecycle": 100, "SocketClients": 128, "SocketMessages": 200},
    {"Name": "socket-heavy-256", "Cases": "socket", "Workers": 32, "Calls": 100, "Fire": 100, "Lifecycle": 100, "SocketClients": 256, "SocketMessages": 200},
    {"Name": "mixed-full", "Cases": "mixed", "Workers": 64, "Calls": 500, "Fire": 1000, "Lifecycle": 500, "SocketClients": 128, "SocketMessages": 100},
]


def run_perf_profile(exe: Path, label: str, profile_spec: dict[str, object], threads: int, iteration: int, timeout_seconds: int) -> dict[str, float]:
    profile_name = str(profile_spec["Name"])
    log_dir = ROOT / "perf-results/logs"
    ensure_dir(log_dir)
    stdout_path = log_dir / f"{label}-{profile_name}-t{threads}-i{iteration}.out"
    stderr_path = log_dir / f"{label}-{profile_name}-t{threads}-i{iteration}.err"
    for path in (stdout_path, stderr_path):
        if path.exists():
            path.unlink()

    env = os.environ.copy()
    env.update(
        {
            "SKYNET_PRELOAD": "tests/perf/preload.lua",
            "SKYNET_THREAD": str(threads),
            "SKYNET_PERF_CASES": str(profile_spec["Cases"]),
            "SKYNET_PERF_WORKERS": str(profile_spec["Workers"]),
            "SKYNET_PERF_CALLS": str(profile_spec["Calls"]),
            "SKYNET_PERF_FIRE": str(profile_spec["Fire"]),
            "SKYNET_PERF_LIFECYCLE": str(profile_spec["Lifecycle"]),
            "SKYNET_PERF_SOCKET_CLIENTS": str(profile_spec["SocketClients"]),
            "SKYNET_PERF_SOCKET_MESSAGES": str(profile_spec["SocketMessages"]),
            "SKYNET_PERF_SOCKET_PORT": str(19291 + (threads * 10) + iteration),
        }
    )
    env.pop("SKYNET_START", None)

    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        proc = subprocess.Popen([str(exe)], cwd=str(ROOT), env=env, stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + timeout_seconds
        state = "TIMEOUT"
        while time.monotonic() < deadline:
            time.sleep(0.5)
            text = safe_read(stdout_path)
            if re.search(r"\[perf\] PASS: perf suite completed", text):
                state = "PASS"
                break
            if FAIL_PATTERN.search(text):
                state = "FAIL"
                break
            code = proc.poll()
            if code is not None:
                state = f"EXIT {code}"
                break
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
    if state != "PASS":
        print_file(stdout_path)
        print_file(stderr_path)
        fail(f"perf profile failed: {profile_name} threads={threads} iteration={iteration} state={state}")
    return read_metrics(stdout_path)


def cmd_perf(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    build_dir = ROOT / args.build_dir
    if not args.no_build:
        if not build_dir.exists():
            configure_build(build_dir, "Release")
        build(build_dir, "Release")
    exe = resolve_exe(build_dir, "Release")
    if not exe:
        fail(f"skynet-cpp executable not found in {build_dir}")

    ensure_dir(ROOT / "perf-results/logs")
    thread_counts = normalize_thread_counts(args.thread_counts)
    all_runs: list[dict[str, object]] = []
    aggregate: dict[str, dict[str, dict[str, float]]] = {}

    for threads in thread_counts:
        for profile_spec in PERF_PROFILES:
            series: dict[str, list[float]] = {}
            for iteration in range(1, args.iterations + 1):
                info(f"Running {profile_spec['Name']} threads={threads} iteration={iteration}/{args.iterations}")
                metrics = run_perf_profile(exe, args.label, profile_spec, threads, iteration, args.timeout_seconds)
                for key, value in metrics.items():
                    if iteration > 1:
                        series.setdefault(key, []).append(float(value))
                all_runs.append(
                    {
                        "profile": profile_spec["Name"],
                        "threads": threads,
                        "iteration": iteration,
                        "warmup": iteration == 1,
                        "metrics": metrics,
                    }
                )
            profile_key = f"{profile_spec['Name']}.t{threads}"
            aggregate[profile_key] = {key: stats(values) for key, values in series.items()}

    result = {
        "label": args.label,
        "mode": args.mode,
        "timestamp": _dt.datetime.now(_dt.timezone.utc).astimezone().isoformat(),
        "iterations": args.iterations,
        "warmup_discarded": True,
        "runs": all_runs,
        "aggregate": aggregate,
    }
    json_path = ROOT / f"perf-results/{args.label}.json"
    md_path = ROOT / f"perf-results/{args.label}.md"
    json_path.write_text(json.dumps(result, indent=4), encoding="utf-8")

    lines = ["# perf " + args.label, "", "| profile | metric | min | median | p95 | max |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for profile_key, metrics in aggregate.items():
        for metric_key, s in metrics.items():
            lines.append(f"| {profile_key} | {metric_key} | {s['min']:.2f} | {s['median']:.2f} | {s['p95']:.2f} | {s['max']:.2f} |")
    md_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    info(f"Wrote {rel(json_path)}")
    info(f"Wrote {rel(md_path)}")


def coverage_summary(rows: list[dict[str, object]]) -> dict[str, object]:
    covered = sum(int(row["Covered"]) for row in rows)
    lines = sum(int(row["Lines"]) for row in rows)
    percent = round(100.0 * covered / lines, 2) if lines else 0.0
    return {"Covered": covered, "Lines": lines, "Percent": percent}


def executable_lua_line(line: str) -> bool:
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


def lua_target_files(scope: str) -> list[Path]:
    if scope == "Stress":
        rels = [
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
        return [ROOT / p for p in rels if (ROOT / p).exists()]

    excluded = {
        "lualib/loader.lua",
        "lualib/skynet/coverage.lua",
        "service/clusteragent.lua",
        "examples/main.lua",
    }
    files: list[Path] = []
    for path in (ROOT / "lualib").rglob("*.lua"):
        if rel(path) not in excluded:
            files.append(path)
    for path in (ROOT / "service").glob("*.lua"):
        if path.name.startswith("test_"):
            continue
        if rel(path) not in excluded:
            files.append(path)
    return sorted(set(files))


def lua_hit_set(lua_coverage_dir: Path, targets: list[Path]) -> set[tuple[str, int]]:
    target_set = {norm(p) for p in targets}
    hits: set[tuple[str, int]] = set()
    if not lua_coverage_dir.exists():
        return hits
    for log in lua_coverage_dir.glob("*.log"):
        for raw in log.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = re.match(r"^(.*):([0-9]+)$", raw.strip())
            if not match:
                continue
            path = norm(match.group(1))
            if path in target_set:
                hits.add((path, int(match.group(2))))
    return hits


def lua_coverage_rows(lua_coverage_dir: Path, targets: list[Path]) -> list[dict[str, object]]:
    hits = lua_hit_set(lua_coverage_dir, targets)
    rows: list[dict[str, object]] = []
    for path in targets:
        npath = norm(path)
        count = 0
        covered = 0
        for idx, line in enumerate(path.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1):
            if not executable_lua_line(line):
                continue
            count += 1
            if (npath, idx) in hits:
                covered += 1
        pct = round(100.0 * covered / count, 2) if count else 100.0
        rows.append({"File": rel(path), "Covered": covered, "Lines": count, "Percent": pct})
    return rows


def cpp_coverage_rows(cov_json: Path) -> list[dict[str, object]]:
    data = json.loads(cov_json.read_text(encoding="utf-8"))
    best: dict[str, dict[str, object]] = {}
    root_text = norm(ROOT)
    for unit in data.get("data", []):
        for file in unit.get("files", []):
            name = str(file["filename"]).replace("\\", "/")
            if not name.startswith(root_text + "/"):
                continue
            relative = name[len(root_text) + 1 :]
            if not relative.startswith("src/"):
                continue
            lines = int(file["summary"]["lines"]["count"])
            covered = int(file["summary"]["lines"]["covered"])
            pct = round(100.0 * covered / lines, 2) if lines else 100.0
            row = {"File": relative, "Covered": covered, "Lines": lines, "Percent": pct}
            if relative not in best or covered > int(best[relative]["Covered"]):
                best[relative] = row
    return list(best.values())


def save_rows(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text(json.dumps(sorted(rows, key=lambda r: (float(r["Percent"]), str(r["File"]))), indent=4), encoding="utf-8")


def assert_coverage(label: str, summary: dict[str, object], threshold: float) -> None:
    if int(summary["Lines"]) == 0:
        fail(f"{label} coverage has no target lines")
    if float(summary["Percent"]) < threshold:
        fail(f"{label} coverage {float(summary['Percent']):.2f}% is below threshold {threshold:.2f}%")


def cmd_coverage(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    if args.cpp_threshold >= 0:
        if args.gate == "Full":
            args.full_cpp_threshold = args.cpp_threshold
        else:
            args.stress_cpp_threshold = args.cpp_threshold
    if args.lua_threshold >= 0:
        if args.gate == "Full":
            args.full_lua_threshold = args.lua_threshold
        else:
            args.stress_lua_threshold = args.lua_threshold

    llvm_cov = find_tool("llvm-cov")
    llvm_profdata = find_tool("llvm-profdata")
    build_path = ROOT / args.build_dir
    report_path = ROOT / args.report_dir
    lua_cov_dir = report_path / "lua"
    if (build_path / "CMakeCache.txt").exists():
        remove_tree(build_path)
    ensure_dir(report_path)
    ensure_dir(lua_cov_dir)
    for pattern in ("*.profraw", "*.profdata"):
        for path in report_path.glob(pattern):
            path.unlink()
    for path in lua_cov_dir.glob("*.log"):
        path.unlink()

    configure_build(build_path, "Debug", coverage=True)
    build(build_path, "Debug")

    exe = resolve_exe(build_path, "Debug")
    cpp_unit = next((p for p in [build_path / "skynet-cpp-unit.exe", build_path / "Debug/skynet-cpp-unit.exe", build_path / "skynet-cpp-unit"] if p.exists()), None)
    if not exe:
        fail(f"Executable not found under {build_path}")
    env_extra = {
        "SKYNET_LUA_COVERAGE": "1",
        "SKYNET_LUA_COVERAGE_DIR": str(lua_cov_dir),
        "LLVM_PROFILE_FILE": str(report_path / "skynet-%p.profraw"),
    }
    if cpp_unit:
        unit_env = os.environ.copy()
        unit_env.update(env_extra)
        run_checked([cpp_unit], env=unit_env)
    run_until_pass(
        exe,
        preload="tests/stress/preload.lua",
        pass_pattern=r"PASS: stress suite completed",
        timeout_seconds=args.stress_timeout_seconds,
        label="Stress suite",
        out=report_path / "stress.out",
        err=report_path / "stress.err",
        thread=args.thread_count,
        env_extra=env_extra,
        wait_on_pass=True,
    )
    if args.gate in ("Full", "Both", "ReportOnly"):
        run_until_pass(
            exe,
            preload="tests/logic/preload.lua",
            pass_pattern=r"PASS: unit coverage suite completed",
            timeout_seconds=args.unit_timeout_seconds,
            label="Unit coverage suite",
            out=report_path / "unit.out",
            err=report_path / "unit.err",
            thread=args.thread_count,
            env_extra=env_extra,
            wait_on_pass=True,
        )

    profraw = sorted(report_path.glob("*.profraw"))
    if not profraw:
        fail("No LLVM profraw files generated")
    profdata = report_path / "skynet.profdata"
    run_checked([llvm_profdata, "merge", "-sparse", *profraw, "-o", profdata])

    export_args: list[str | Path] = [llvm_cov, "export", exe]
    show_args: list[str | Path] = [llvm_cov, "show", exe]
    if cpp_unit:
        export_args.append(f"-object={cpp_unit}")
        show_args.append(f"-object={cpp_unit}")
    export_args += [f"-instr-profile={profdata}", "-format=text"]
    if platform.system() != "Windows":
        export_args += ["-ignore-filename-regex=.*3rdparty.*", ROOT / "src"]
    cpp_json = report_path / "cpp-coverage.json"
    info("+ " + " ".join(str(x) for x in export_args))
    with cpp_json.open("w", encoding="utf-8") as stdout:
        completed = subprocess.run([str(x) for x in export_args], cwd=str(ROOT), stdout=stdout)
    if completed.returncode != 0:
        fail("llvm-cov export failed")

    html_dir = report_path / "cpp-html"
    remove_tree(html_dir)
    show_args += [f"-instr-profile={profdata}", "-format=html", f"-output-dir={html_dir}"]
    if platform.system() != "Windows":
        show_args += ["-ignore-filename-regex=.*3rdparty.*", ROOT / "src"]
    run_checked(show_args)

    stress_cpp_rows = cpp_coverage_rows(cpp_json)
    full_cpp_rows = stress_cpp_rows
    stress_lua_rows = lua_coverage_rows(lua_cov_dir, lua_target_files("Stress"))
    full_lua_rows = lua_coverage_rows(lua_cov_dir, lua_target_files("Full"))
    stress_cpp = coverage_summary(stress_cpp_rows)
    stress_lua = coverage_summary(stress_lua_rows)
    full_cpp = coverage_summary(full_cpp_rows)
    full_lua = coverage_summary(full_lua_rows)

    groups = {
        "cluster": ["lualib/skynet/cluster.lua", "service/clusterd.lua", "service/clustersender.lua"],
        "socketchannel": ["lualib/skynet/socketchannel.lua"],
        "debug_console": ["service/debug_console.lua"],
        "db": ["lualib/skynet/db/redis.lua", "lualib/skynet/db/mysql.lua", "lualib/skynet/db/mongo.lua"],
    }
    stress_modules = {
        name: coverage_summary([row for row in stress_lua_rows if row["File"] in set(paths)])
        for name, paths in groups.items()
    }

    save_rows(report_path / "cpp-stress-coverage.json", stress_cpp_rows)
    save_rows(report_path / "lua-stress-coverage.json", stress_lua_rows)
    save_rows(report_path / "cpp-full-coverage.json", full_cpp_rows)
    save_rows(report_path / "lua-full-coverage.json", full_lua_rows)

    summary = {
        "Gate": args.gate,
        "Stress": {
            "Cpp": stress_cpp,
            "Lua": stress_lua,
            "Modules": stress_modules,
            "CppThreshold": args.stress_cpp_threshold,
            "LuaThreshold": args.stress_lua_threshold,
            "ModuleThreshold": args.stress_module_threshold,
        },
        "Full": {
            "Cpp": full_cpp,
            "Lua": full_lua,
            "CppThreshold": args.full_cpp_threshold,
            "LuaThreshold": args.full_lua_threshold,
        },
        "Reports": {
            "CppHtml": norm(html_dir / "index.html"),
            "CppStressJson": norm(report_path / "cpp-stress-coverage.json"),
            "LuaStressJson": norm(report_path / "lua-stress-coverage.json"),
            "CppFullJson": norm(report_path / "cpp-full-coverage.json"),
            "LuaFullJson": norm(report_path / "lua-full-coverage.json"),
        },
    }
    (report_path / "coverage-summary.json").write_text(json.dumps(summary, indent=4), encoding="utf-8")

    info(f"Stress C++ line coverage: {stress_cpp['Percent']:.2f}% ({stress_cpp['Covered']}/{stress_cpp['Lines']}), threshold {args.stress_cpp_threshold:.2f}%")
    info(f"Stress Lua line coverage: {stress_lua['Percent']:.2f}% ({stress_lua['Covered']}/{stress_lua['Lines']}), threshold {args.stress_lua_threshold:.2f}%")
    info(f"Full C++ line coverage: {full_cpp['Percent']:.2f}% ({full_cpp['Covered']}/{full_cpp['Lines']}), threshold {args.full_cpp_threshold:.2f}%")
    info(f"Full Lua line coverage: {full_lua['Percent']:.2f}% ({full_lua['Covered']}/{full_lua['Lines']}), threshold {args.full_lua_threshold:.2f}%")
    for name, item in stress_modules.items():
        info(f"Stress module {name} line coverage: {item['Percent']:.2f}% ({item['Covered']}/{item['Lines']}), threshold {args.stress_module_threshold:.2f}%")
    info(f"Coverage gate: {args.gate}")
    info(f"C++ HTML report: {norm(html_dir / 'index.html')}")
    info(f"Coverage summary: {norm(report_path / 'coverage-summary.json')}")

    if args.gate in ("Stress", "Both"):
        assert_coverage("Stress C++", stress_cpp, args.stress_cpp_threshold)
        assert_coverage("Stress Lua", stress_lua, args.stress_lua_threshold)
        for name, item in stress_modules.items():
            assert_coverage(f"Stress module {name}", item, args.stress_module_threshold)
    if args.gate in ("Full", "Both"):
        assert_coverage("Full C++", full_cpp, args.full_cpp_threshold)
        assert_coverage("Full Lua", full_lua, args.full_lua_threshold)


def get_median_map(doc: dict[str, object]) -> dict[str, float]:
    out: dict[str, float] = {}
    aggregate = doc.get("aggregate", {})
    if isinstance(aggregate, dict):
        for profile, metrics in aggregate.items():
            if isinstance(metrics, dict):
                for metric, value in metrics.items():
                    if isinstance(value, dict):
                        out[f"{profile}.{metric}"] = float(value.get("median", 0.0))
    return out


def cmd_compare_perf(args: argparse.Namespace) -> None:
    baseline = json.loads(Path(args.baseline).read_text(encoding="utf-8"))
    current = json.loads(Path(args.current).read_text(encoding="utf-8"))
    base = get_median_map(baseline)
    cur = get_median_map(current)
    failed: list[str] = []
    rows = ["# Performance comparison", "", "| metric | baseline median | current median | delta |", "| --- | ---: | ---: | ---: |"]
    for key in sorted(base):
        if key not in cur:
            failed.append(f"missing metric {key}")
            continue
        b = base[key]
        c = cur[key]
        delta = ((c / b) - 1.0) * 100.0 if b else 0.0
        rows.append(f"| {key} | {b:.2f} | {c:.2f} | {delta:.2f}% |")
        if b > 0 and delta < -args.allowed_regression_percent:
            failed.append(f"{key} regressed {delta:.2f}%")
    report = Path(args.report)
    if not report.is_absolute():
        report = ROOT / report
    ensure_dir(report.parent)
    report.write_text("\n".join(rows) + "\n", encoding="utf-8")
    info(f"Wrote {norm(report)}")
    if failed:
        for item in failed:
            print(item, file=sys.stderr)
        fail("performance comparison failed")


def cmd_soak(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    build_dir = ROOT / args.build_dir
    if not args.no_build:
        configure_build(build_dir, "Release")
        build(build_dir, "Release")
    exe = resolve_exe(build_dir, "Release")
    if not exe:
        fail(f"skynet-cpp executable not found in {build_dir}")
    ensure_dir(ROOT / "soak-results/logs")
    deadline = time.monotonic() + args.minutes * 60
    runs: list[dict[str, object]] = []
    index = 0
    while time.monotonic() < deadline:
        index += 1
        started = time.monotonic()
        out = ROOT / f"soak-results/logs/soak-{index}.out"
        err = ROOT / f"soak-results/logs/soak-{index}.err"
        try:
            run_until_pass(
                exe,
                preload="tests/stress/preload.lua",
                pass_pattern=r"PASS: stress suite completed",
                timeout_seconds=args.per_run_timeout_seconds,
                label=f"soak run {index}",
                out=out,
                err=err,
                thread=args.thread,
            )
            state = "PASS"
        except Exception:
            state = "FAIL"
            runs.append({"index": index, "state": state, "elapsed_seconds": round(time.monotonic() - started, 2), "stdout": rel(out), "stderr": rel(err)})
            (ROOT / "soak-results/soak-runs.json").write_text(json.dumps(runs, indent=4), encoding="utf-8")
            raise
        runs.append({"index": index, "state": state, "elapsed_seconds": round(time.monotonic() - started, 2), "stdout": rel(out), "stderr": rel(err)})
        (ROOT / "soak-results/soak-runs.json").write_text(json.dumps(runs, indent=4), encoding="utf-8")
    summary = {"minutes": args.minutes, "thread": args.thread, "runs": len(runs), "status": "PASS"}
    (ROOT / "soak-results/summary.json").write_text(json.dumps(summary, indent=4), encoding="utf-8")
    info(f"soak PASS runs={len(runs)}")


def docker(args: list[str]) -> str:
    return run_capture(["docker", *args])


def ensure_container(name: str, image: str, docker_args: list[str]) -> None:
    exists = docker(["ps", "-a", "--filter", f"name=^/{name}$", "--format", "{{.Names}}"]).strip()
    if exists == name:
        running = docker(["ps", "--filter", f"name=^/{name}$", "--format", "{{.Names}}"]).strip()
        if running != name:
            run_checked(["docker", "start", name])
        return
    run_checked(["docker", "run", "-d", "--name", name, *docker_args, image])


def wait_until(label: str, func, seconds: int) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if func():
                info(f"{label} ready")
                return
        except Exception:
            pass
        time.sleep(1)
    fail(f"{label} did not become ready within {seconds} seconds")


def cmd_docker_stress(args: argparse.Namespace) -> None:
    os.chdir(ROOT)
    redis_name = "skynet-cpp-test-redis"
    mysql_name = "skynet-cpp-test-mysql"
    mongo_name = "skynet-cpp-test-mongo"
    redis_port = 26379
    mysql_port = 23306
    mongo_port = 27018
    mysql_password = "skynet"
    mysql_database = "stress"
    mongo_database = "stress"

    ensure_container(redis_name, "redis:7-alpine", ["-p", f"{redis_port}:6379"])
    ensure_container(
        mysql_name,
        "mysql:5.7",
        [
            "-p",
            f"{mysql_port}:3306",
            "-e",
            f"MYSQL_ROOT_PASSWORD={mysql_password}",
            "-e",
            f"MYSQL_DATABASE={mysql_database}",
            "--health-cmd",
            f"mysqladmin ping -uroot -p{mysql_password} --silent",
            "--health-interval",
            "2s",
            "--health-timeout",
            "2s",
            "--health-retries",
            "60",
        ],
    )
    ensure_container(mongo_name, "mongo:5.0", ["-p", f"{mongo_port}:27017"])

    wait_until("redis", lambda: "PONG" in docker(["exec", redis_name, "redis-cli", "ping"]), 60)
    wait_until("mysql", lambda: "mysqld is alive" in docker(["exec", mysql_name, "mysqladmin", "ping", "-uroot", f"-p{mysql_password}", "--silent"]), 120)
    wait_until("mongo", lambda: "1" in docker(["exec", mongo_name, "mongo", "--quiet", "--eval", "db.adminCommand('ping').ok"]), 120)

    os.environ.update(
        {
            "SKYNET_TEST_REDIS_PORT": str(redis_port),
            "SKYNET_TEST_MYSQL_PORT": str(mysql_port),
            "SKYNET_TEST_MYSQL_USER": "root",
            "SKYNET_TEST_MYSQL_PASSWORD": mysql_password,
            "SKYNET_TEST_MYSQL_DATABASE": mysql_database,
            "SKYNET_TEST_MONGO_PORT": str(mongo_port),
            "SKYNET_TEST_MONGO_DATABASE": mongo_database,
        }
    )
    if args.coverage:
        cmd_coverage(
            SimpleNamespace(
                thread_count=args.thread_count,
                gate=args.gate,
                stress_cpp_threshold=70.0,
                stress_lua_threshold=30.0,
                stress_module_threshold=90.0,
                full_cpp_threshold=90.0,
                full_lua_threshold=90.0,
                cpp_threshold=-1.0,
                lua_threshold=-1.0,
                stress_timeout_seconds=args.timeout_seconds,
                unit_timeout_seconds=args.timeout_seconds,
                build_dir="build-coverage",
                report_dir="coverage-report",
            )
        )
    else:
        build(ROOT / "build", "Debug")
        exe = resolve_exe(ROOT / "build", "Debug")
        if not exe:
            fail("skynet-cpp executable not found; configure the build first")
        run_until_pass(
            exe,
            preload="tests/stress/preload.lua",
            pass_pattern=r"PASS: stress suite completed",
            timeout_seconds=args.timeout_seconds,
            label="docker stress",
            out=ROOT / "stress-test.out",
            err=ROOT / "stress-test.err",
            thread=args.thread_count,
        )
    if not args.keep_containers:
        info("Docker test containers are left running for reuse. Pass --keep-containers is accepted for compatibility.")


def cmd_docker_linux_coverage(args: argparse.Namespace) -> None:
    apt_update = "true" if args.no_apt_update else "apt-get update"
    script = f"""
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
{apt_update}
apt-get install -y --no-install-recommends ca-certificates cmake ninja-build clang llvm libclang-rt-18-dev g++ make
bash tools/run_coverage.sh --gate {args.gate} --thread-count {args.thread_count} --stress-timeout-seconds {args.timeout_seconds} --unit-timeout-seconds {args.timeout_seconds}
"""
    run_checked(["docker", "run", "--rm", "-v", f"{ROOT}:/work", "-w", "/work", args.image, "bash", "-lc", script])


LINUX_PERF_SCRIPT = r'''set -euo pipefail
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
'''


def cmd_docker_linux_perf(args: argparse.Namespace) -> None:
    root = ROOT.parent
    threads = " ".join(str(x) for x in normalize_thread_counts(args.thread_counts))
    script = (
        LINUX_PERF_SCRIPT.replace("__LABEL__", args.label)
        .replace("__THREADS__", threads)
        .replace("__ITERATIONS__", str(args.iterations))
        .replace("__TIMEOUT_SECONDS__", str(args.timeout_seconds))
        .replace("__SKIP_NATIVE__", "1" if args.skip_native else "0")
    )
    ensure_dir(ROOT / "perf-results")
    script_path = ROOT / f"perf-results/{args.label}-run.sh"
    script_path.write_text(script.replace("\r\n", "\n"), encoding="utf-8")
    run_checked(["docker", "run", "--rm", "-v", f"{root}:/work", "-w", "/work/skynet-cpp", "debian:bookworm", "bash", f"/work/skynet-cpp/perf-results/{args.label}-run.sh"])
    info(f"Linux perf logs written under perf-results/logs with label {args.label}")


def cmd_version(args: argparse.Namespace) -> None:
    manifest = ROOT / "tools/python/manifest.json"
    runtime = os.environ.get("SKYNET_TOOLS_PYTHON", sys.executable)
    info(f"skynet-tools python={sys.version.split()[0]} executable={runtime}")
    if manifest.exists():
        info(manifest.read_text(encoding="utf-8"))


def add_common_coverage_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--thread-count", type=int, default=16)
    parser.add_argument("--gate", choices=["Stress", "Full", "Both", "ReportOnly"], default="Stress")
    parser.add_argument("--stress-cpp-threshold", type=float, default=70.0)
    parser.add_argument("--stress-lua-threshold", type=float, default=30.0)
    parser.add_argument("--stress-module-threshold", type=float, default=90.0)
    parser.add_argument("--full-cpp-threshold", type=float, default=90.0)
    parser.add_argument("--full-lua-threshold", type=float, default=90.0)
    parser.add_argument("--cpp-threshold", type=float, default=-1.0)
    parser.add_argument("--lua-threshold", type=float, default=-1.0)
    parser.add_argument("--stress-timeout-seconds", type=int, default=600)
    parser.add_argument("--unit-timeout-seconds", type=int, default=300)
    parser.add_argument("--build-dir", default="build-coverage")
    parser.add_argument("--report-dir", default="coverage-report")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="skynet-tool")
    parser.add_argument("--version", action="store_true", help="print tool and Python runtime information")
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("version")
    p.set_defaults(func=cmd_version)

    p = sub.add_parser("verify")
    p.add_argument("--mode", choices=["Quick", "Full"], default="Quick")
    p.add_argument("--build-dir", default="build")
    p.add_argument("--logic-timeout-seconds", type=int, default=300)
    p.add_argument("--stress-timeout-seconds", type=int, default=600)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("package")
    p.add_argument("--build-config", choices=["Debug", "Release", "RelWithDebInfo", "MinSizeRel"], default="Release")
    p.add_argument("--build-dir", default="build-package")
    p.add_argument("--install-dir", default="dist/skynet-cpp")
    p.add_argument("--clean", action="store_true")
    p.set_defaults(func=cmd_package)

    p = sub.add_parser("package-smoke")
    p.add_argument("--install-dir", default="dist/skynet-cpp")
    p.add_argument("--thread", type=int, default=4)
    p.add_argument("--timeout-seconds", type=int, default=20)
    p.set_defaults(func=cmd_package_smoke)

    p = sub.add_parser("coverage")
    add_common_coverage_args(p)
    p.set_defaults(func=cmd_coverage)

    p = sub.add_parser("perf")
    p.add_argument("--label", default="manual")
    p.add_argument("--mode", choices=["Baseline", "Optimized", "Native", "Manual"], default="Manual")
    p.add_argument("--thread-counts", nargs="+", default=["8", "16", "32"])
    p.add_argument("--iterations", type=int, default=5)
    p.add_argument("--timeout-seconds", type=int, default=600)
    p.add_argument("--build-dir", default="build-perf")
    p.add_argument("--no-build", action="store_true")
    p.set_defaults(func=cmd_perf)

    p = sub.add_parser("compare-perf")
    p.add_argument("--baseline", required=True)
    p.add_argument("--current", required=True)
    p.add_argument("--allowed-regression-percent", type=float, default=5.0)
    p.add_argument("--report", default="perf-results/comparison.md")
    p.set_defaults(func=cmd_compare_perf)

    p = sub.add_parser("soak")
    p.add_argument("--minutes", type=int, default=30)
    p.add_argument("--thread", type=int, default=16)
    p.add_argument("--per-run-timeout-seconds", type=int, default=900)
    p.add_argument("--build-dir", default="build-soak")
    p.add_argument("--no-build", action="store_true")
    p.set_defaults(func=cmd_soak)

    p = sub.add_parser("docker-stress")
    p.add_argument("--coverage", action="store_true")
    p.add_argument("--gate", choices=["Stress", "Full", "Both", "ReportOnly"], default="Stress")
    p.add_argument("--thread-count", type=int, default=16)
    p.add_argument("--timeout-seconds", type=int, default=300)
    p.add_argument("--keep-containers", action="store_true")
    p.set_defaults(func=cmd_docker_stress)

    p = sub.add_parser("docker-linux-coverage")
    p.add_argument("--image", default="ubuntu:24.04")
    p.add_argument("--gate", choices=["Stress", "Full", "Both", "ReportOnly"], default="Full")
    p.add_argument("--thread-count", type=int, default=16)
    p.add_argument("--timeout-seconds", type=int, default=900)
    p.add_argument("--no-apt-update", action="store_true")
    p.set_defaults(func=cmd_docker_linux_coverage)

    p = sub.add_parser("docker-linux-perf")
    p.add_argument("--label", default="linux-perf")
    p.add_argument("--thread-counts", nargs="+", default=["8", "16", "32"])
    p.add_argument("--iterations", type=int, default=5)
    p.add_argument("--timeout-seconds", type=int, default=600)
    p.add_argument("--skip-native", action="store_true")
    p.set_defaults(func=cmd_docker_linux_perf)
    return parser


def normalize_legacy_args(argv: list[str]) -> list[str]:
    mapping = {
        "-Mode": "--mode",
        "-BuildDir": "--build-dir",
        "-LogicTimeoutSeconds": "--logic-timeout-seconds",
        "-StressTimeoutSeconds": "--stress-timeout-seconds",
        "-BuildConfig": "--build-config",
        "-InstallDir": "--install-dir",
        "-Clean": "--clean",
        "-Thread": "--thread",
        "-TimeoutSeconds": "--timeout-seconds",
        "-ThreadCount": "--thread-count",
        "-Gate": "--gate",
        "-StressCppThreshold": "--stress-cpp-threshold",
        "-StressLuaThreshold": "--stress-lua-threshold",
        "-StressModuleThreshold": "--stress-module-threshold",
        "-FullCppThreshold": "--full-cpp-threshold",
        "-FullLuaThreshold": "--full-lua-threshold",
        "-CppThreshold": "--cpp-threshold",
        "-LuaThreshold": "--lua-threshold",
        "-UnitTimeoutSeconds": "--unit-timeout-seconds",
        "-ReportDir": "--report-dir",
        "-Label": "--label",
        "-ThreadCounts": "--thread-counts",
        "-Iterations": "--iterations",
        "-NoBuild": "--no-build",
        "-Baseline": "--baseline",
        "-Current": "--current",
        "-AllowedRegressionPercent": "--allowed-regression-percent",
        "-Report": "--report",
        "-Minutes": "--minutes",
        "-PerRunTimeoutSeconds": "--per-run-timeout-seconds",
        "-Coverage": "--coverage",
        "-KeepContainers": "--keep-containers",
        "-Image": "--image",
        "-NoAptUpdate": "--no-apt-update",
        "-SkipNative": "--skip-native",
    }
    return [mapping.get(item, item) for item in argv]


def main(argv: list[str] | None = None) -> int:
    argv = normalize_legacy_args(list(sys.argv[1:] if argv is None else argv))
    parser = build_parser()
    if not argv:
        parser.print_help()
        return 0
    if argv == ["--version"]:
        cmd_version(SimpleNamespace())
        return 0
    ns = parser.parse_args(argv)
    if not hasattr(ns, "func"):
        parser.print_help()
        return 2
    try:
        ns.func(ns)
        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
