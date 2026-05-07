param(
    [switch]$Coverage,
    [ValidateSet("Stress", "Full", "Both", "ReportOnly")]
    [string]$Gate = "Stress",
    [int]$ThreadCount = 16,
    [int]$TimeoutSeconds = 300,
    [switch]$KeepContainers
)

$ErrorActionPreference = "Stop"

function Run-Checked($argv) {
    Write-Host ("+ " + ($argv -join " "))
    & $argv[0] @($argv | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $($argv -join ' ')"
    }
}

function Find-CMake() {
    $cmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $fallback = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (Test-Path $fallback) { return $fallback }
    throw "cmake not found"
}

function Ensure-Container {
    param(
        [string]$Name,
        [string]$Image,
        [string[]]$DockerArgs
    )

    $exists = docker ps -a --filter "name=^/$Name$" --format "{{.Names}}"
    if ($exists -eq $Name) {
        $running = docker ps --filter "name=^/$Name$" --format "{{.Names}}"
        if ($running -ne $Name) {
            Run-Checked @("docker", "start", $Name)
        }
        return
    }

    $argv = @("docker", "run", "-d", "--name", $Name)
    $argv += $DockerArgs
    $argv += $Image
    Run-Checked $argv
}

function Wait-Until($label, $scriptBlock, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            if (& $scriptBlock) {
                Write-Host "$label ready"
                return
            }
        } catch {
        }
        Start-Sleep -Seconds 1
    }
    throw "$label did not become ready within $seconds seconds"
}

$redisName = "skynet-cpp-test-redis"
$mysqlName = "skynet-cpp-test-mysql"
$mongoName = "skynet-cpp-test-mongo"
$redisPort = 26379
$mysqlPort = 23306
$mongoPort = 27018
$mysqlPassword = "skynet"
$mysqlDatabase = "stress"
$mongoDatabase = "stress"

Ensure-Container -Name $redisName -Image "redis:7-alpine" -DockerArgs @("-p", "$redisPort`:6379")
Ensure-Container -Name $mysqlName -Image "mysql:5.7" -DockerArgs @(
    "-p", "$mysqlPort`:3306",
    "-e", "MYSQL_ROOT_PASSWORD=$mysqlPassword",
    "-e", "MYSQL_DATABASE=$mysqlDatabase",
    "--health-cmd", "mysqladmin ping -uroot -p$mysqlPassword --silent",
    "--health-interval", "2s",
    "--health-timeout", "2s",
    "--health-retries", "60"
)
Ensure-Container -Name $mongoName -Image "mongo:5.0" -DockerArgs @("-p", "$mongoPort`:27017")

Wait-Until "redis" { (docker exec $redisName redis-cli ping) -match "PONG" } 60
Wait-Until "mysql" { (docker exec $mysqlName mysqladmin ping "-uroot" "-p$mysqlPassword" "--silent") -match "mysqld is alive" } 120
Wait-Until "mongo" { (docker exec $mongoName mongo --quiet --eval "db.adminCommand('ping').ok") -match "1" } 120

$env:SKYNET_TEST_REDIS_PORT = [string]$redisPort
$env:SKYNET_TEST_MYSQL_PORT = [string]$mysqlPort
$env:SKYNET_TEST_MYSQL_USER = "root"
$env:SKYNET_TEST_MYSQL_PASSWORD = $mysqlPassword
$env:SKYNET_TEST_MYSQL_DATABASE = $mysqlDatabase
$env:SKYNET_TEST_MONGO_PORT = [string]$mongoPort
$env:SKYNET_TEST_MONGO_DATABASE = $mongoDatabase

try {
    if ($Coverage) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File tools/run_coverage.ps1 -Gate $Gate -ThreadCount $ThreadCount
        if ($LASTEXITCODE -ne 0) {
            throw "coverage stress failed"
        }
    } else {
        $cmake = Find-CMake
        Run-Checked @($cmake, "--build", "build", "--config", "Debug", "--parallel")

        $exe = "build/Debug/skynet-cpp.exe"
        if (-not (Test-Path $exe)) {
            $exe = "build/skynet-cpp.exe"
        }
        if (-not (Test-Path $exe)) {
            throw "skynet-cpp executable not found; configure the build first"
        }

        $env:SKYNET_PRELOAD = "tests/stress/preload.lua"
        Remove-Item Env:SKYNET_START -ErrorAction SilentlyContinue
        $env:SKYNET_THREAD = [string]$ThreadCount
        Remove-Item stress-test.out, stress-test.err -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $exe -WorkingDirectory (Get-Location) -NoNewWindow -PassThru `
            -RedirectStandardOutput stress-test.out -RedirectStandardError stress-test.err

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        $state = "TIMEOUT"
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (Test-Path stress-test.out) {
                $text = Get-Content stress-test.out -Raw
                if ($text -match "PASS: stress suite completed") {
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
        Get-Content stress-test.out -ErrorAction SilentlyContinue
        Get-Content stress-test.err -ErrorAction SilentlyContinue
        if ($state -ne "PASS") {
            throw "stress suite failed: $state"
        }
    }
} finally {
    if (-not $KeepContainers) {
        Write-Host "Docker test containers are left running for reuse. Pass -KeepContainers is accepted for compatibility."
    }
}
