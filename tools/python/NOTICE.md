# Vendored Python Runtime

This repository vendors CPython runtime archives from
[`python-build-standalone`](https://github.com/astral-sh/python-build-standalone)
so the developer tools can run offline on Windows, Linux, and macOS.

- Source release: `20260414`
- CPython version: `3.13.13`
- Variant: `install_only`
- Architectures: Windows x64, Linux x64 glibc, macOS x64, macOS arm64

The committed archives live under `tools/python/archives/` and are stored with
Git LFS. First use extracts the current platform into ignored
`tools/python/runtime/`.

The extracted runtime directories retain the upstream `LICENSE.txt` files from
the downloaded distributions. See `manifest.json` for exact asset names, archive
paths, source hashes, and local runtime paths.
