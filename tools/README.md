# skynet-cpp Tools

Tooling is implemented in Python stdlib under `tools/py/skynet_tools`.
Platform scripts are thin entrypoints only:

- Windows: use `*.bat` scripts, for example `tools\verify.bat --mode Quick`.
- Linux/macOS: use `*.sh` scripts, for example `bash tools/verify.sh --mode Quick`.
- Unified CLI: `tools\skynet-tool.bat <command>` or `bash tools/skynet-tool.sh <command>`.

The tools prefer the vendored Python runtime. The repository stores it as Git
LFS archives under `tools/python/archives/`; the first run extracts the current
platform into ignored `tools/python/runtime/`. Run `git lfs pull` after clone so
the archives are available for offline use. Set `SKYNET_TOOLS_PYTHON` only when
you want to override the bundled runtime for local debugging.

Common commands:

```bat
tools\verify.bat --mode Quick
tools\run_coverage.bat --gate Full --thread-count 16
tools\package.bat --build-config Release
tools\run_package_smoke.bat
tools\run_perf_benchmark.bat --label manual --thread-counts 8,16,32
```

The Python runtime manifest, archive names, and upstream SHA256 hashes are
recorded in `tools/python/manifest.json`.
