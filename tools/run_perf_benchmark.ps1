param(
    [string]$Label = "manual",
    [ValidateSet("Baseline", "Optimized", "Native", "Manual")]
    [string]$Mode = "Manual",
    [string[]]$ThreadCounts = @("8", "16", "32"),
    [int]$Iterations = 5,
    [int]$TimeoutSeconds = 600,
    [string]$BuildDir = "build-perf",
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

function Percentile([double[]]$Values, [double]$P) {
    if ($Values.Count -eq 0) { return 0.0 }
    $sorted = @($Values | Sort-Object)
    $idx = [int][Math]::Ceiling(($P / 100.0) * $sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [double]$sorted[$idx]
}

function Stats([double[]]$Values) {
    if ($Values.Count -eq 0) {
        return [ordered]@{ min = 0.0; median = 0.0; p95 = 0.0; max = 0.0 }
    }
    $sorted = @($Values | Sort-Object)
    return [ordered]@{
        min = [double]$sorted[0]
        median = Percentile $sorted 50
        p95 = Percentile $sorted 95
        max = [double]$sorted[$sorted.Count - 1]
    }
}

function Read-Metrics([string]$Path) {
    $metrics = @{}
    $text = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    foreach ($m in [regex]::Matches($text, "\[perf\] METRIC case=([^ ]+) name=([^ ]+) value=([0-9.]+)")) {
        $case = $m.Groups[1].Value
        $name = $m.Groups[2].Value
        $value = [double]$m.Groups[3].Value
        $key = "$case.$name"
        $metrics[$key] = $value
    }
    return $metrics
}

function Run-OneProfile($Exe, $ProfileName, $Threads, $Env) {
    $stdout = "perf-results/logs/$Label-$ProfileName-t$Threads-i$($Env.Iteration).out"
    $stderr = "perf-results/logs/$Label-$ProfileName-t$Threads-i$($Env.Iteration).err"
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    $env:SKYNET_PRELOAD = "tests/perf/preload.lua"
    $env:SKYNET_THREAD = [string]$Threads
    $env:SKYNET_PERF_CASES = $Env.Cases
    $env:SKYNET_PERF_WORKERS = [string]$Env.Workers
    $env:SKYNET_PERF_CALLS = [string]$Env.Calls
    $env:SKYNET_PERF_FIRE = [string]$Env.Fire
    $env:SKYNET_PERF_LIFECYCLE = [string]$Env.Lifecycle
    $env:SKYNET_PERF_SOCKET_CLIENTS = [string]$Env.SocketClients
    $env:SKYNET_PERF_SOCKET_MESSAGES = [string]$Env.SocketMessages
    $env:SKYNET_PERF_SOCKET_PORT = [string](19291 + ($Threads * 10) + $Env.Iteration)
    Remove-Item Env:SKYNET_START -ErrorAction SilentlyContinue

    $p = Start-Process -FilePath $Exe -WorkingDirectory (Get-Location) -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $state = "TIMEOUT"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $stdout) {
            $text = Get-Content $stdout -Raw
            if ($text -match "\[perf\] PASS: perf suite completed") {
                $state = "PASS"
                break
            }
            if ($text -match "CASE failed|callback error|exception:|No dispatch function|Unknown response session|timed out") {
                $state = "FAIL"
                break
            }
        }
        if ($p.HasExited) {
            $state = "EXIT $($p.ExitCode)"
            break
        }
    }

    if (-not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    if ($state -ne "PASS") {
        Get-Content $stdout -ErrorAction SilentlyContinue
        Get-Content $stderr -ErrorAction SilentlyContinue
        throw "perf profile failed: $ProfileName threads=$Threads iteration=$($Env.Iteration) state=$state"
    }

    return Read-Metrics $stdout
}

$cmake = Find-CMake
if (-not $NoBuild) {
    if (-not (Test-Path $BuildDir)) {
        Run-Checked @($cmake, "-S", ".", "-B", $BuildDir, "-DCMAKE_BUILD_TYPE=Release")
    }
    Run-Checked @($cmake, "--build", $BuildDir, "--config", "Release", "--parallel")
}

$exeCandidates = @(
    "$BuildDir/Release/skynet-cpp.exe",
    "$BuildDir/skynet-cpp.exe",
    "$BuildDir/skynet-cpp"
)
$exe = $exeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) {
    throw "skynet-cpp executable not found in $BuildDir"
}

New-Item -ItemType Directory -Force perf-results, perf-results/logs | Out-Null

$normalizedThreadCounts = @()
foreach ($item in $ThreadCounts) {
    foreach ($part in ([string]$item -split ",")) {
        $part = $part.Trim()
        if ($part -ne "") {
            $normalizedThreadCounts += [int]$part
        }
    }
}
if ($normalizedThreadCounts.Count -eq 0) {
    throw "ThreadCounts cannot be empty"
}

$profiles = @(
    [ordered]@{ Name = "actor-heavy"; Cases = "actor"; Workers = 64; Calls = 1000; Fire = 2000; Lifecycle = 100; SocketClients = 32; SocketMessages = 50 },
    [ordered]@{ Name = "scheduler-heavy"; Cases = "scheduler"; Workers = 128; Calls = 200; Fire = 400; Lifecycle = 100; SocketClients = 32; SocketMessages = 50 },
    [ordered]@{ Name = "lifecycle-heavy"; Cases = "lifecycle"; Workers = 32; Calls = 100; Fire = 100; Lifecycle = 1000; SocketClients = 32; SocketMessages = 50 },
    [ordered]@{ Name = "socket-heavy"; Cases = "socket"; Workers = 32; Calls = 100; Fire = 100; Lifecycle = 100; SocketClients = 128; SocketMessages = 200 },
    [ordered]@{ Name = "socket-heavy-256"; Cases = "socket"; Workers = 32; Calls = 100; Fire = 100; Lifecycle = 100; SocketClients = 256; SocketMessages = 200 },
    [ordered]@{ Name = "mixed-full"; Cases = "mixed"; Workers = 64; Calls = 500; Fire = 1000; Lifecycle = 500; SocketClients = 128; SocketMessages = 100 }
)

$allRuns = @()
$aggregate = [ordered]@{}

foreach ($threads in $normalizedThreadCounts) {
    foreach ($profile in $profiles) {
        $series = @{}
        foreach ($i in 1..$Iterations) {
            $envSpec = [ordered]@{}
            foreach ($k in $profile.Keys) { $envSpec[$k] = $profile[$k] }
            $envSpec.Iteration = $i
            Write-Host "Running $($profile.Name) threads=$threads iteration=$i/$Iterations"
            $metrics = Run-OneProfile $exe $profile.Name $threads $envSpec
            foreach ($key in $metrics.Keys) {
                if (-not $series.ContainsKey($key)) { $series[$key] = New-Object System.Collections.Generic.List[double] }
                if ($i -gt 1) {
                    $series[$key].Add([double]$metrics[$key])
                }
            }
            $allRuns += [ordered]@{
                profile = $profile.Name
                threads = $threads
                iteration = $i
                warmup = ($i -eq 1)
                metrics = $metrics
            }
        }

        $profileKey = "$($profile.Name).t$threads"
        $aggregate[$profileKey] = [ordered]@{}
        foreach ($key in $series.Keys) {
            $aggregate[$profileKey][$key] = Stats ([double[]]$series[$key].ToArray())
        }
    }
}

$result = [ordered]@{
    label = $Label
    mode = $Mode
    timestamp = (Get-Date).ToString("o")
    iterations = $Iterations
    warmup_discarded = $true
    runs = $allRuns
    aggregate = $aggregate
}

$jsonPath = "perf-results/$Label.json"
$mdPath = "perf-results/$Label.md"
$result | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $jsonPath

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# perf $Label")
$md.Add("")
$md.Add("| profile | metric | min | median | p95 | max |")
$md.Add("| --- | ---: | ---: | ---: | ---: | ---: |")
foreach ($profileKey in $aggregate.Keys) {
    foreach ($metricKey in $aggregate[$profileKey].Keys) {
        $s = $aggregate[$profileKey][$metricKey]
        $md.Add(('| {0} | {1} | {2:N2} | {3:N2} | {4:N2} | {5:N2} |' -f $profileKey, $metricKey, $s.min, $s.median, $s.p95, $s.max))
    }
}
$md | Set-Content -Encoding UTF8 $mdPath

Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
