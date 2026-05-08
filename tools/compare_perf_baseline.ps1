param(
    [Parameter(Mandatory=$true)]
    [string]$Baseline,
    [Parameter(Mandatory=$true)]
    [string]$Current,
    [double]$AllowedRegressionPercent = 5.0,
    [string]$Report = "perf-results/comparison.md"
)

$ErrorActionPreference = "Stop"

function Read-Json($path) {
    if (-not (Test-Path $path)) {
        throw "perf json not found: $path"
    }
    return Get-Content $path -Raw | ConvertFrom-Json
}

function Get-MedianMap($doc) {
    $map = @{}
    $aggregate = $doc.aggregate
    foreach ($profile in $aggregate.PSObject.Properties) {
        foreach ($metric in $profile.Value.PSObject.Properties) {
            $key = "$($profile.Name).$($metric.Name)"
            $map[$key] = [double]$metric.Value.median
        }
    }
    return $map
}

$baseDoc = Read-Json $Baseline
$curDoc = Read-Json $Current
$base = Get-MedianMap $baseDoc
$cur = Get-MedianMap $curDoc

$failed = @()
$rows = New-Object System.Collections.Generic.List[string]
$rows.Add("# Performance comparison")
$rows.Add("")
$rows.Add("| metric | baseline median | current median | delta |")
$rows.Add("| --- | ---: | ---: | ---: |")

foreach ($key in ($base.Keys | Sort-Object)) {
    if (-not $cur.ContainsKey($key)) {
        $failed += "missing metric $key"
        continue
    }
    $b = [double]$base[$key]
    $c = [double]$cur[$key]
    $delta = if ($b -ne 0) { (($c / $b) - 1.0) * 100.0 } else { 0.0 }
    $rows.Add(('| {0} | {1:N2} | {2:N2} | {3:N2}% |' -f $key, $b, $c, $delta))
    if ($b -gt 0 -and $delta -lt (-1.0 * $AllowedRegressionPercent)) {
        $failed += ("{0} regressed {1:N2}%" -f $key, $delta)
    }
}

New-Item -ItemType Directory -Force (Split-Path -Parent $Report) | Out-Null
$rows | Set-Content -Encoding UTF8 $Report
Write-Host "Wrote $Report"

if ($failed.Count -gt 0) {
    $failed | ForEach-Object { Write-Error $_ }
    throw "performance comparison failed"
}
