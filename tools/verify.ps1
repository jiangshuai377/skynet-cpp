param(
    [ValidateSet("Quick", "Full")]
    [string]$Mode = "Quick",
    [string]$BuildDir = "build",
    [int]$LogicTimeoutSeconds = 300,
    [int]$StressTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"

function Find-CMake() {
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $fallback) { return $fallback }
    throw "cmake not found"
}

function Run-Checked([string[]]$Argv) {
    Write-Host ("+ " + ($Argv -join " "))
    & $Argv[0] @($Argv | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $($Argv -join ' ')"
    }
}

function Resolve-Exe($Dir, $Config) {
    $candidates = @(
        "$Dir/$Config/skynet-cpp.exe",
        "$Dir/skynet-cpp.exe",
        "$Dir/skynet-cpp"
    )
    return $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Run-Suite($Exe, $Preload, $PassPattern, $TimeoutSeconds, $Label) {
    New-Item -ItemType Directory -Force verify-results | Out-Null
    $out = "verify-results/$Label.out"
    $err = "verify-results/$Label.err"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    $env:SKYNET_PRELOAD = $Preload
    $env:SKYNET_THREAD = "8"
    Remove-Item Env:SKYNET_START -ErrorAction SilentlyContinue

    $p = Start-Process -FilePath $Exe -WorkingDirectory (Get-Location) -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = "TIMEOUT"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $text = if (Test-Path $out) { Get-Content $out -Raw } else { "" }
        $errText = if (Test-Path $err) { Get-Content $err -Raw } else { "" }
        $all = $text + "`n" + $errText
        if ($all -match $PassPattern) {
            $state = "PASS"
            break
        }
        if ($all -match "callback error|timed out|No dispatch function|Unknown message type|Unknown response session") {
            $state = "FAIL"
            break
        }
        if ($p.HasExited) {
            $state = "EXIT $($p.ExitCode)"
            break
        }
    }
    if (-not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Content $out -ErrorAction SilentlyContinue
    Get-Content $err -ErrorAction SilentlyContinue
    if ($state -ne "PASS") {
        throw "$Label failed: $state"
    }
}

$cmake = Find-CMake
Push-Location (Resolve-Path (Join-Path $PSScriptRoot ".."))
try {
    Run-Checked @($cmake, "-S", ".", "-B", $BuildDir, "-DCMAKE_BUILD_TYPE=Debug")
    Run-Checked @($cmake, "--build", $BuildDir, "--config", "Debug", "--parallel")
    $debugExe = Resolve-Exe $BuildDir "Debug"
    if (-not $debugExe) { throw "Debug skynet-cpp executable not found" }
    Run-Suite $debugExe "tests/logic/preload.lua" "PASS: unit coverage suite completed" $LogicTimeoutSeconds "logic-debug"

    Run-Checked @($cmake, "-S", ".", "-B", "$BuildDir-release", "-DCMAKE_BUILD_TYPE=Release")
    Run-Checked @($cmake, "--build", "$BuildDir-release", "--config", "Release", "--parallel")
    $releaseExe = Resolve-Exe "$BuildDir-release" "Release"
    if (-not $releaseExe) { throw "Release skynet-cpp executable not found" }

    if ($Mode -eq "Full") {
        Run-Suite $debugExe "tests/stress/preload.lua" "PASS: stress suite completed" $StressTimeoutSeconds "stress-debug"
        & (Join-Path $PSScriptRoot "package.ps1") -BuildConfig Release
        & (Join-Path $PSScriptRoot "run_package_smoke.ps1")
        & (Join-Path $PSScriptRoot "run_perf_benchmark.ps1") -Label "verify-smoke" -ThreadCounts @("8") -Iterations 2 -BuildDir "$BuildDir-release" -NoBuild
        & (Join-Path $PSScriptRoot "run_coverage.ps1") -Gate ReportOnly -StressCppThreshold 0 -StressLuaThreshold 0 -FullCppThreshold 0 -FullLuaThreshold 0
    }

    Write-Host "verify $Mode PASS"
} finally {
    Pop-Location
}
