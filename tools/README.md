# skynet-cpp Runtime Tools

This directory intentionally keeps only the minimal tools required by the
runtime repository itself:

- `verify.bat` / `verify.sh` - Debug build, logic suite, optional stress suite,
  and Release build smoke.
- `package.bat` / `package.sh` - build and install a runnable package.
- `run_package_smoke.bat` / `run_package_smoke.sh` - run the installed example
  preload from the package root.
- `run_linux_coverage.sh` - Linux CI coverage smoke with report-only output.

Full coverage gates, performance benchmarks, Docker DB stress, long-run
validation, native skynet comparison, and heavy tool runtime assets live in the
best-practice project tools at the parent `testa/tools/` layer.

Common commands:

```bat
tools\verify.bat --mode Quick
tools\package.bat --build-config Release --clean
tools\run_package_smoke.bat --timeout-seconds 60
```

Linux/macOS:

```bash
bash tools/verify.sh --mode Quick
bash tools/package.sh --build-config Release --clean
bash tools/run_package_smoke.sh --timeout-seconds 60
```
