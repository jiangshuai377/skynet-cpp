param(
    [string]$InstallDir = "dist/skynet-cpp",
    [int]$Thread = 4,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"

$Repo = Resolve-Path (Join-Path $PSScriptRoot "..")
$Root = Resolve-Path (Join-Path $Repo $InstallDir)
$ExeCandidates = @(
    (Join-Path $Root "bin/skynet-cpp.exe"),
    (Join-Path $Root "bin/skynet-cpp")
)
$Exe = $ExeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Exe) {
    throw "Installed skynet-cpp executable not found under $Root"
}

$Out = Join-Path $Repo "package-results/package-smoke.out"
$Err = Join-Path $Repo "package-results/package-smoke.err"
New-Item -ItemType Directory -Force -Path (Join-Path $Repo "package-results") | Out-Null
Remove-Item $Out, $Err -ErrorAction SilentlyContinue

Push-Location $Root
try {
    $env:SKYNET_THREAD = [string]$Thread
    $env:SKYNET_PRELOAD = "examples/preload.lua"
    $p = Start-Process -FilePath $Exe -WorkingDirectory $Root -NoNewWindow -PassThru `
        -RedirectStandardOutput $Out -RedirectStandardError $Err

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = "TIMEOUT"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $text = if (Test-Path $Out) { Get-Content $Out -Raw } else { "" }
        $errText = if (Test-Path $Err) { Get-Content $Err -Raw } else { "" }
        if (($text + $errText) -match "PASS: launcher LAUNCH works") {
            $state = "PASS"
            break
        }
        if (($text + $errText) -match "callback error|No dispatch function|Unknown message type|loader failed") {
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

    Get-Content $Out -ErrorAction SilentlyContinue
    Get-Content $Err -ErrorAction SilentlyContinue
    if ($state -ne "PASS") {
        throw "Package smoke failed: $state"
    }
} finally {
    Pop-Location
}
