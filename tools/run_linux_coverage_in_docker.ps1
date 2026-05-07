param(
    [string]$Image = "ubuntu:24.04",
    [ValidateSet("Stress", "Full", "Both", "ReportOnly")]
    [string]$Gate = "Full",
    [int]$ThreadCount = 16,
    [int]$TimeoutSeconds = 900,
    [switch]$NoAptUpdate
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path ".").Path
$aptUpdate = if ($NoAptUpdate) { "true" } else { "apt-get update" }
$script = @"
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
$aptUpdate
apt-get install -y --no-install-recommends ca-certificates cmake ninja-build clang llvm libclang-rt-18-dev python3 g++ make
bash tools/run_linux_coverage.sh --gate $Gate --thread-count $ThreadCount --stress-timeout-seconds $TimeoutSeconds --unit-timeout-seconds $TimeoutSeconds
"@

docker run --rm `
    -v "${repo}:/work" `
    -w /work `
    $Image `
    bash -lc $script

if ($LASTEXITCODE -ne 0) {
    throw "Linux Docker coverage failed"
}
