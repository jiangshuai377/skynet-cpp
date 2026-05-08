param(
    [int]$Minutes = 30,
    [int]$Thread = 16,
    [int]$PerRunTimeoutSeconds = 900,
    [string]$BuildDir = "build-soak",
    [switch]$NoBuild
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

Push-Location (Resolve-Path (Join-Path $PSScriptRoot ".."))
try {
    $cmake = Find-CMake
    if (-not $NoBuild) {
        Run-Checked @($cmake, "-S", ".", "-B", $BuildDir, "-DCMAKE_BUILD_TYPE=Release")
        Run-Checked @($cmake, "--build", $BuildDir, "--config", "Release", "--parallel")
    }

    $exe = @(
        "$BuildDir/Release/skynet-cpp.exe",
        "$BuildDir/skynet-cpp.exe",
        "$BuildDir/skynet-cpp"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $exe) {
        throw "skynet-cpp executable not found in $BuildDir"
    }

    New-Item -ItemType Directory -Force soak-results, soak-results/logs | Out-Null
    $deadline = (Get-Date).AddMinutes($Minutes)
    $runs = @()
    $index = 0
    while ((Get-Date) -lt $deadline) {
        $index++
        $out = "soak-results/logs/soak-$index.out"
        $err = "soak-results/logs/soak-$index.err"
        Remove-Item $out, $err -ErrorAction SilentlyContinue

        $env:SKYNET_PRELOAD = "tests/stress/preload.lua"
        $env:SKYNET_THREAD = [string]$Thread
        Remove-Item Env:SKYNET_START -ErrorAction SilentlyContinue

        $started = Get-Date
        $p = Start-Process -FilePath $exe -WorkingDirectory (Get-Location) -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $runDeadline = (Get-Date).AddSeconds($PerRunTimeoutSeconds)
        $state = "TIMEOUT"
        while ((Get-Date) -lt $runDeadline) {
            Start-Sleep -Milliseconds 500
            $text = if (Test-Path $out) { Get-Content $out -Raw } else { "" }
            $errText = if (Test-Path $err) { Get-Content $err -Raw } else { "" }
            $all = $text + "`n" + $errText
            if ($all -match "PASS: stress suite completed") {
                $state = "PASS"
                break
            }
            if ($all -match "callback error|timed out|No dispatch function|Unknown message type|Unknown response session|lost response") {
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

        $elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 2)
        $runs += [pscustomobject]@{
            index = $index
            state = $state
            elapsed_seconds = $elapsed
            stdout = $out
            stderr = $err
        }
        $runs | ConvertTo-Json -Depth 4 | Set-Content "soak-results/soak-runs.json"

        if ($state -ne "PASS") {
            Get-Content $out -ErrorAction SilentlyContinue
            Get-Content $err -ErrorAction SilentlyContinue
            throw "soak run $index failed: $state"
        }
    }

    [pscustomobject]@{
        minutes = $Minutes
        thread = $Thread
        runs = $runs.Count
        status = "PASS"
    } | ConvertTo-Json -Depth 4 | Set-Content "soak-results/summary.json"
    Write-Host "soak PASS runs=$($runs.Count)"
} finally {
    Pop-Location
}
