param(
    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildConfig = "Release",
    [string]$BuildDir = "build-package",
    [string]$InstallDir = "dist/skynet-cpp",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

function Find-Tool($name, $fallback = $null) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($fallback -and (Test-Path $fallback)) { return $fallback }
    throw "Required tool not found: $name"
}

$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$CMake = Find-Tool "cmake" "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$BuildPath = Join-Path $Repo $BuildDir
$InstallPath = Join-Path $Repo $InstallDir

Push-Location $Repo
try {
    if ($Clean) {
        Remove-Item $BuildPath, $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path (Join-Path $BuildPath "CMakeCache.txt"))) {
        & $CMake -S . -B $BuildPath -DCMAKE_BUILD_TYPE=$BuildConfig
        if ($LASTEXITCODE -ne 0) {
            throw "cmake configure failed"
        }
    }

    & $CMake --build $BuildPath --config $BuildConfig --parallel
    if ($LASTEXITCODE -ne 0) {
        throw "cmake build failed"
    }

    Remove-Item $InstallPath -Recurse -Force -ErrorAction SilentlyContinue
    & $CMake --install $BuildPath --config $BuildConfig --prefix $InstallPath
    if ($LASTEXITCODE -ne 0) {
        throw "cmake install failed"
    }

    $summary = [pscustomobject]@{
        BuildConfig = $BuildConfig
        BuildDir = (Resolve-Path $BuildPath).Path
        InstallDir = (Resolve-Path $InstallPath).Path
        Layout = @("bin", "lualib", "service", "examples", "doc")
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $Repo "package-results") | Out-Null
    $summary | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $Repo "package-results/package-summary.json")
    $summary | Format-List
} finally {
    Pop-Location
}
