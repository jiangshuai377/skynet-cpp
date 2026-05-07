# skynet-cpp tests

This directory keeps test-only code out of runtime services.

- `stress/`: pressure and concurrency suites. Main entry: `tests/stress/test_stress.lua`.
- `logic/`: Lua logic, regression, and coverage suites. Main coverage entry: `tests/logic/test_unit_coverage.lua`.
- `cpp_unit.cpp`: C++ unit coverage binary source, built only when `SKYNET_ENABLE_COVERAGE=ON`.

Runtime services stay in `service/`. Demo services stay in `examples/`.
