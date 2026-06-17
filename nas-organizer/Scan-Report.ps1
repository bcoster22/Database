<#
.SYNOPSIS
    READ-ONLY. Reports where space is being used on C: so you can decide what to
    move. Moves nothing. Run this first.

.EXAMPLE
    .\Scan-Report.ps1                       # scans your user profile
    .\Scan-Report.ps1 -Root 'C:\' -Top 30   # whole drive, top 30
#>
[CmdletBinding()]
param(
    [string] $Root = $env:USERPROFILE,
    [int]    $Top = 20,
    [long]   $BigFileBytes = 200MB,
    [int]    $StaleDays = 180,
    [string] $OutCsv = "$env:USERPROFILE\nas-scan-report.csv"
)
$ErrorActionPreference = 'SilentlyContinue'
function Human([long]$n){ foreach($u in 'B','KB','MB','GB','TB'){ if($n -lt 1024){return ('{0:N1} {1}' -f $n,$u)}; $n/=1024 } }

Write-Host "Scanning $Root ... (read-only, this can take a minute)`n" -ForegroundColor Cyan

# --- Largest immediate subfolders ------------------------------------------
$folders = Get-ChildItem -LiteralPath $Root -Directory -Force |
  ForEach-Object {
    $sum = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force |
            Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Folder=$_.FullName; Bytes=[long]$sum }
  } | Sort-Object Bytes -Descending

Write-Host "=== Largest folders under $Root ===" -ForegroundColor Yellow
$folders | Select-Object -First $Top |
  Format-Table @{n='Size';e={Human $_.Bytes};a='right'}, Folder -AutoSize

# --- Biggest individual files ----------------------------------------------
Write-Host "`n=== Biggest files (>= $(Human $BigFileBytes)) ===" -ForegroundColor Yellow
$bigfiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
  Where-Object Length -ge $BigFileBytes | Sort-Object Length -Descending
$bigfiles | Select-Object -First $Top |
  Format-Table @{n='Size';e={Human $_.Length};a='right'},
               @{n='Modified';e={$_.LastWriteTime.ToString('yyyy-MM-dd')}}, FullName -AutoSize

# --- Stale large files (candidates to archive) -----------------------------
$cut = (Get-Date).AddDays(-$StaleDays)
Write-Host "`n=== Large + not touched in $StaleDays days (prime move candidates) ===" -ForegroundColor Yellow
$bigfiles | Where-Object LastWriteTime -lt $cut | Select-Object -First $Top |
  Format-Table @{n='Size';e={Human $_.Length};a='right'},
               @{n='Modified';e={$_.LastWriteTime.ToString('yyyy-MM-dd')}}, FullName -AutoSize

# --- CSV for follow-up ------------------------------------------------------
$folders | Select-Object Folder, Bytes, @{n='Human';e={Human $_.Bytes}} |
  Export-Csv -LiteralPath $OutCsv -NoTypeInformation
Write-Host "`nFolder totals written to: $OutCsv" -ForegroundColor Green
Write-Host "Next: feed the folders you want cleared to Organize-ToNAS.ps1 (preview first)." -ForegroundColor Green
