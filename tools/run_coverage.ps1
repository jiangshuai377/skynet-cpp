param(
    [int]$ThreadCount = 16,
    [ValidateSet("Stress", "Full", "Both", "ReportOnly")]
    [string]$Gate = "Stress",
    [double]$StressCppThreshold = 70.0,
    [double]$StressLuaThreshold = 30.0,
    [double]$StressModuleThreshold = 90.0,
    [double]$FullCppThreshold = 90.0,
    [double]$FullLuaThreshold = 90.0,
    [double]$CppThreshold = -1.0,
    [double]$LuaThreshold = -1.0,
    [int]$StressTimeoutSeconds = 600,
    [int]$UnitTimeoutSeconds = 300,
    [string]$BuildDir = "build-coverage",
    [string]$ReportDir = "coverage-report"
)

$ErrorActionPreference = "Stop"

function Find-Tool($name, $fallback = $null) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($fallback -and (Test-Path $fallback)) { return $fallback }
    throw "Required tool not found: $name"
}

function Normalize-PathText($path) {
    return ([IO.Path]::GetFullPath($path)).Replace('\', '/')
}

function Run-Checked($argv) {
    Write-Host ("+ " + ($argv -join " "))
    & $argv[0] @($argv | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $($argv -join ' ')"
    }
}

$repo = Normalize-PathText (Resolve-Path ".")
if ($CppThreshold -ge 0) {
    if ($Gate -eq "Full") {
        $FullCppThreshold = $CppThreshold
    } else {
        $StressCppThreshold = $CppThreshold
    }
}
if ($LuaThreshold -ge 0) {
    if ($Gate -eq "Full") {
        $FullLuaThreshold = $LuaThreshold
    } else {
        $StressLuaThreshold = $LuaThreshold
    }
}

$cmake = Find-Tool "cmake" "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$clangcl = Find-Tool "clang-cl"
$llvmCov = Find-Tool "llvm-cov"
$llvmProfdata = Find-Tool "llvm-profdata"
$mt = Get-Command mt -ErrorAction SilentlyContinue
if ($mt) {
    $mtPath = $mt.Source
} else {
    $mtPath = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Recurse -Filter mt.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\x64\\mt.exe$" } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $mtPath) {
    throw "Required tool not found: mt.exe"
}

$buildPath = Normalize-PathText $BuildDir
$reportPath = Normalize-PathText $ReportDir
$luaCoverageDir = "$reportPath/lua"

if (Test-Path "$buildPath/CMakeCache.txt") {
    Remove-Item $buildPath -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $reportPath | Out-Null
New-Item -ItemType Directory -Force -Path $luaCoverageDir | Out-Null
Remove-Item "$reportPath/*.profraw", "$reportPath/*.profdata", "$luaCoverageDir/*.log" -ErrorAction SilentlyContinue

$ninja = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninja) {
    $vsNinja = "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
    if (Test-Path $vsNinja) {
        $ninja = [pscustomobject]@{ Source = $vsNinja }
    }
}
if ($ninja) {
    Run-Checked @($cmake, "-S", ".", "-B", $buildPath, "-G", "Ninja",
        "-DCMAKE_C_COMPILER=$clangcl", "-DCMAKE_CXX_COMPILER=$clangcl",
        "-DCMAKE_MAKE_PROGRAM=$($ninja.Source)",
        "-DCMAKE_MT=$mtPath",
        "-DCMAKE_BUILD_TYPE=Debug", "-DSKYNET_ENABLE_COVERAGE=ON")
    Run-Checked @($cmake, "--build", $buildPath, "--parallel")
    $exe = "$buildPath/skynet-cpp.exe"
    $cppUnitExe = "$buildPath/skynet-cpp-unit.exe"
} else {
    Run-Checked @($cmake, "-S", ".", "-B", $buildPath, "-G", "Visual Studio 17 2022",
        "-T", "ClangCL", "-DSKYNET_ENABLE_COVERAGE=ON")
    Run-Checked @($cmake, "--build", $buildPath, "--config", "Debug", "--parallel")
    $exe = "$buildPath/Debug/skynet-cpp.exe"
    $cppUnitExe = "$buildPath/Debug/skynet-cpp-unit.exe"
}

if (-not (Test-Path $exe)) {
    throw "Executable not found: $exe"
}

$env:SKYNET_PRELOAD = "tests/stress/preload.lua"
Remove-Item Env:SKYNET_START -ErrorAction SilentlyContinue
$env:SKYNET_THREAD = [string]$ThreadCount
$env:SKYNET_LUA_COVERAGE = "1"
$env:SKYNET_LUA_COVERAGE_DIR = $luaCoverageDir
$env:LLVM_PROFILE_FILE = "$reportPath/skynet-%p.profraw"

if (Test-Path $cppUnitExe) {
    Run-Checked @($cppUnitExe)
}

$out = "$reportPath/stress.out"
$err = "$reportPath/stress.err"
Remove-Item $out, $err -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $exe -WorkingDirectory $repo -NoNewWindow -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err

$deadline = (Get-Date).AddSeconds($StressTimeoutSeconds)
$state = "TIMEOUT"
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $out) {
        $text = Get-Content $out -Raw
        if ($text -match "PASS: stress suite completed") {
            $state = "PASS"
            break
        }
        if ($text -match "callback error|timed out|No dispatch function|Unknown message type|Unknown response session") {
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

Get-Content $out -ErrorAction SilentlyContinue
Get-Content $err -ErrorAction SilentlyContinue

if ($state -ne "PASS") {
    throw "Stress suite did not pass under coverage: $state"
}

if ($Gate -eq "Full" -or $Gate -eq "Both" -or $Gate -eq "ReportOnly") {
    $env:SKYNET_PRELOAD = "tests/logic/preload.lua"
    $unitOut = "$reportPath/unit.out"
    $unitErr = "$reportPath/unit.err"
    Remove-Item $unitOut, $unitErr -ErrorAction SilentlyContinue

    $unitProcess = Start-Process -FilePath $exe -WorkingDirectory $repo -NoNewWindow -PassThru `
        -RedirectStandardOutput $unitOut -RedirectStandardError $unitErr

    $unitDeadline = (Get-Date).AddSeconds($UnitTimeoutSeconds)
    $unitState = "TIMEOUT"
    while ((Get-Date) -lt $unitDeadline) {
        Start-Sleep -Milliseconds 250
        if (Test-Path $unitOut) {
            $unitText = Get-Content $unitOut -Raw
            if ($unitText -match "PASS: unit coverage suite completed") {
                $unitState = "PASS"
                break
            }
            if ($unitText -match "callback error|timed out|No dispatch function|Unknown message type|Unknown response session") {
                $unitState = "FAIL"
                break
            }
        }
        if ($unitProcess.HasExited) {
            $unitState = "EXIT $($unitProcess.ExitCode)"
            break
        }
    }
    if (-not $unitProcess.HasExited) {
        Stop-Process -Id $unitProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Get-Content $unitOut -ErrorAction SilentlyContinue
    Get-Content $unitErr -ErrorAction SilentlyContinue

    if ($unitState -ne "PASS") {
        throw "Unit coverage suite did not pass: $unitState"
    }
}

$profraw = Get-ChildItem $reportPath -Filter "*.profraw" -ErrorAction SilentlyContinue
if (-not $profraw) {
    throw "No LLVM profraw files generated"
}

$profdata = "$reportPath/skynet.profdata"
$mergeArgs = @($llvmProfdata, "merge", "-sparse")
$mergeArgs += @($profraw | ForEach-Object { $_.FullName })
$mergeArgs += @("-o", $profdata)
Run-Checked $mergeArgs

$jsonPath = "$reportPath/cpp-coverage.json"
$exportArgs = @($exe)
if (Test-Path $cppUnitExe) {
    $exportArgs += @("-object=$cppUnitExe")
}
& $llvmCov export @exportArgs "-instr-profile=$profdata" "-format=text" > $jsonPath
if ($LASTEXITCODE -ne 0) {
    throw "llvm-cov export failed"
}

$htmlDir = "$reportPath/cpp-html"
Remove-Item $htmlDir -Recurse -Force -ErrorAction SilentlyContinue
$showArgs = @($exe)
if (Test-Path $cppUnitExe) {
    $showArgs += @("-object=$cppUnitExe")
}
& $llvmCov show @showArgs "-instr-profile=$profdata" "-format=html" "-output-dir=$htmlDir" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "llvm-cov show failed"
}

$cov = Get-Content $jsonPath -Raw | ConvertFrom-Json

function New-CoverageSummary($rows) {
    $covered = 0
    $count = 0
    foreach ($row in $rows) {
        $covered += [int]$row.Covered
        $count += [int]$row.Lines
    }
    if ($count -eq 0) {
        return [pscustomobject]@{ Covered = 0; Lines = 0; Percent = 0.0 }
    }
    return [pscustomobject]@{
        Covered = $covered
        Lines = $count
        Percent = [math]::Round((100.0 * $covered / $count), 2)
    }
}

function Get-CppCoverageRows($include) {
    $rows = @()
    foreach ($file in $cov.data[0].files) {
        $name = $file.filename.Replace('\', '/')
        if (-not $name.StartsWith("$repo/")) {
            continue
        }
        $rel = $name.Substring($repo.Length + 1)
        if (-not (& $include $rel)) {
            continue
        }
        $count = [int]$file.summary.lines.count
        $covered = [int]$file.summary.lines.covered
        $pct = if ($count -gt 0) { 100.0 * $covered / $count } else { 100.0 }
        $rows += [pscustomobject]@{
            File = $rel
            Covered = $covered
            Lines = $count
            Percent = [math]::Round($pct, 2)
        }
    }
    return $rows
}

function Get-LuaTargetFiles($scope) {
    if ($scope -eq "Stress") {
        $stressRel = @(
            "lualib/bson.lua",
            "lualib/sharedata.lua",
            "lualib/skynet/cluster.lua",
            "lualib/skynet.lua",
            "lualib/skynet/coverage.lua",
            "lualib/skynet/crypt.lua",
            "lualib/skynet/db/mongo.lua",
            "lualib/skynet/db/mysql.lua",
            "lualib/skynet/db/redis.lua",
            "lualib/skynet/debug.lua",
            "lualib/skynet/multicast.lua",
            "lualib/skynet/socketchannel.lua",
            "lualib/socket.lua",
            "service/clusterd.lua",
            "service/clustersender.lua",
            "service/debug_console.lua",
            "service/launcher.lua",
            "service/multicastd.lua",
            "service/sharedatad.lua"
        )
        return @($stressRel | ForEach-Object {
            $path = Normalize-PathText (Join-Path $repo $_)
            if (Test-Path $path) { $path }
        })
    }

    $files = @()
    $excludedFullLua = @{
        "lualib/loader.lua" = $true
        "lualib/skynet/coverage.lua" = $true
        "service/clusteragent.lua" = $true
        "examples/main.lua" = $true
    }
    $files += Get-ChildItem "$repo/lualib" -Recurse -Filter "*.lua" | Where-Object {
        $rel = (Normalize-PathText $_.FullName).Substring($repo.Length + 1)
        -not $excludedFullLua.ContainsKey($rel)
    } | ForEach-Object { Normalize-PathText $_.FullName }
    $files += Get-ChildItem "$repo/service" -Filter "*.lua" | Where-Object {
        $rel = (Normalize-PathText $_.FullName).Substring($repo.Length + 1)
        $_.Name -notlike "test_*.lua" -and
            -not $excludedFullLua.ContainsKey($rel)
    } | ForEach-Object { Normalize-PathText $_.FullName }
    return @($files | Sort-Object -Unique)
}

function Get-LuaHitSet($targetLuaFiles) {
    $targetSet = @{}
    foreach ($f in $targetLuaFiles) {
        $targetSet[$f] = $true
    }

    $hits = @{}
    Get-ChildItem $luaCoverageDir -Filter "*.log" -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Content $_.FullName | ForEach-Object {
            $lineText = $_.Trim()
            if ($lineText -match "^(.*):([0-9]+)$") {
                $file = Normalize-PathText $matches[1]
                $line = [int]$matches[2]
                if ($targetSet.ContainsKey($file)) {
                    $hits["$file`:$line"] = $true
                }
            }
        }
    }
    return $hits
}

function Test-LuaExecutableLine($line) {
    $trim = $line.Trim()
    if ($trim.Length -eq 0 -or $trim.StartsWith("--")) {
        return $false
    }
    if ($trim -match "^(local\s+)?function\b") {
        return $false
    }
    if ($trim -match "^[A-Za-z_][A-Za-z0-9_]*\s*=\s*function\b") {
        return $false
    }
    if ($trim -match "^\[[^\]]+\]\s*=\s*function\b") {
        return $false
    }
    if ($trim -match "^end[,]?$") {
        return $false
    }
    if ($trim -eq "else") {
        return $false
    }
    if ($trim -match "^\}?\)?[,]?$") {
        return $false
    }
    if ($trim -match "^[{}(),]+$") {
        return $false
    }
    return $true
}

function Get-LuaCoverageRows($targetLuaFiles) {
    $hits = Get-LuaHitSet $targetLuaFiles
    $rows = @()
    foreach ($file in $targetLuaFiles) {
        $lines = Get-Content $file
        $fileCount = 0
        $fileCovered = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if (-not (Test-LuaExecutableLine $lines[$i])) {
                continue
            }
            $fileCount++
            if ($hits.ContainsKey("$file`:$($i + 1)")) {
                $fileCovered++
            }
        }
        $pct = if ($fileCount -gt 0) { 100.0 * $fileCovered / $fileCount } else { 100.0 }
        $rows += [pscustomobject]@{
            File = $file.Substring($repo.Length + 1)
            Covered = $fileCovered
            Lines = $fileCount
            Percent = [math]::Round($pct, 2)
        }
    }
    return $rows
}

function Save-CoverageRows($path, $rows) {
    $rows | Sort-Object Percent, File | ConvertTo-Json -Depth 3 | Set-Content $path
}

function Assert-Coverage($label, $summary, $threshold) {
    if ($summary.Lines -eq 0) {
        throw "$label coverage has no target lines"
    }
    if ($summary.Percent -lt $threshold) {
        throw ("{0} coverage {1:N2}% is below threshold {2:N2}%" -f $label, $summary.Percent, $threshold)
    }
}

function Get-RowsByRelativePath($rows, $relativePaths) {
    $set = @{}
    foreach ($path in $relativePaths) {
        $set[$path] = $true
    }
    return @($rows | Where-Object { $set.ContainsKey($_.File) })
}

# Stress coverage is the pressure-suite governance target: runtime C++ plus the Lua
# modules/services directly exercised by tests/stress/test_stress.lua.
$stressCppRows = Get-CppCoverageRows { param($rel) $rel -like "src/*" }
$stressLuaRows = Get-LuaCoverageRows (Get-LuaTargetFiles "Stress")
$stressCppSummary = New-CoverageSummary $stressCppRows
$stressLuaSummary = New-CoverageSummary $stressLuaRows

$stressModuleGroups = [ordered]@{
    cluster = @(
        "lualib/skynet/cluster.lua",
        "service/clusterd.lua",
        "service/clustersender.lua"
    )
    socketchannel = @(
        "lualib/skynet/socketchannel.lua"
    )
    debug_console = @(
        "service/debug_console.lua"
    )
    db = @(
        "lualib/skynet/db/redis.lua",
        "lualib/skynet/db/mysql.lua",
        "lualib/skynet/db/mongo.lua"
    )
}
$stressModuleSummaries = [ordered]@{}
foreach ($groupName in $stressModuleGroups.Keys) {
    $groupRows = Get-RowsByRelativePath $stressLuaRows $stressModuleGroups[$groupName]
    $stressModuleSummaries[$groupName] = New-CoverageSummary $groupRows
}

# Full library coverage is a separate unit-coverage governance target. It keeps the
# 90% bar for all first-party src/lualib/service production code, but it is not the
# default gate for the pressure suite.
$fullCppRows = Get-CppCoverageRows { param($rel) $rel -like "src/*" }
$fullLuaRows = Get-LuaCoverageRows (Get-LuaTargetFiles "Full")
$fullCppSummary = New-CoverageSummary $fullCppRows
$fullLuaSummary = New-CoverageSummary $fullLuaRows

Save-CoverageRows "$reportPath/cpp-stress-coverage.json" $stressCppRows
Save-CoverageRows "$reportPath/lua-stress-coverage.json" $stressLuaRows
Save-CoverageRows "$reportPath/cpp-full-coverage.json" $fullCppRows
Save-CoverageRows "$reportPath/lua-full-coverage.json" $fullLuaRows

$summary = [pscustomobject]@{
    Gate = $Gate
    Stress = [pscustomobject]@{
        Cpp = $stressCppSummary
        Lua = $stressLuaSummary
        Modules = $stressModuleSummaries
        CppThreshold = $StressCppThreshold
        LuaThreshold = $StressLuaThreshold
        ModuleThreshold = $StressModuleThreshold
    }
    Full = [pscustomobject]@{
        Cpp = $fullCppSummary
        Lua = $fullLuaSummary
        CppThreshold = $FullCppThreshold
        LuaThreshold = $FullLuaThreshold
    }
    Reports = [pscustomobject]@{
        CppHtml = "$htmlDir/index.html"
        CppStressJson = "$reportPath/cpp-stress-coverage.json"
        LuaStressJson = "$reportPath/lua-stress-coverage.json"
        CppFullJson = "$reportPath/cpp-full-coverage.json"
        LuaFullJson = "$reportPath/lua-full-coverage.json"
    }
}
$summary | ConvertTo-Json -Depth 6 | Set-Content "$reportPath/coverage-summary.json"

Write-Host ("Stress C++ line coverage: {0:N2}% ({1}/{2}), threshold {3:N2}%" -f `
    $stressCppSummary.Percent, $stressCppSummary.Covered, $stressCppSummary.Lines, $StressCppThreshold)
Write-Host ("Stress Lua line coverage: {0:N2}% ({1}/{2}), threshold {3:N2}%" -f `
    $stressLuaSummary.Percent, $stressLuaSummary.Covered, $stressLuaSummary.Lines, $StressLuaThreshold)
Write-Host ("Full C++ line coverage: {0:N2}% ({1}/{2}), threshold {3:N2}%" -f `
    $fullCppSummary.Percent, $fullCppSummary.Covered, $fullCppSummary.Lines, $FullCppThreshold)
Write-Host ("Full Lua line coverage: {0:N2}% ({1}/{2}), threshold {3:N2}%" -f `
    $fullLuaSummary.Percent, $fullLuaSummary.Covered, $fullLuaSummary.Lines, $FullLuaThreshold)
foreach ($groupName in $stressModuleSummaries.Keys) {
    $groupSummary = $stressModuleSummaries[$groupName]
    Write-Host ("Stress module {0} line coverage: {1:N2}% ({2}/{3}), threshold {4:N2}%" -f `
        $groupName, $groupSummary.Percent, $groupSummary.Covered, $groupSummary.Lines, $StressModuleThreshold)
}
Write-Host "Coverage gate: $Gate"
Write-Host "C++ HTML report: $htmlDir/index.html"
Write-Host "Coverage summary: $reportPath/coverage-summary.json"

if ($Gate -eq "Stress" -or $Gate -eq "Both") {
    Assert-Coverage "Stress C++" $stressCppSummary $StressCppThreshold
    Assert-Coverage "Stress Lua" $stressLuaSummary $StressLuaThreshold
    foreach ($groupName in $stressModuleSummaries.Keys) {
        Assert-Coverage "Stress module $groupName" $stressModuleSummaries[$groupName] $StressModuleThreshold
    }
}
if ($Gate -eq "Full" -or $Gate -eq "Both") {
    Assert-Coverage "Full C++" $fullCppSummary $FullCppThreshold
    Assert-Coverage "Full Lua" $fullLuaSummary $FullLuaThreshold
}
