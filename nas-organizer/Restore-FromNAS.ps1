<#
.SYNOPSIS
    Reverse an Organize-ToNAS run: move files from their NAS target back to the
    original source path, using the index CSV.

.DESCRIPTION
    Reads the index produced by Organize-ToNAS.ps1 and, for every successful
    move, copies the file from TargetPath back to SourcePath (verifying SHA256
    when one was recorded), then removes the NAS copy.

    DRY RUN by default. Add -Execute to actually restore.

.EXAMPLE
    .\Restore-FromNAS.ps1 -IndexPath "$env:USERPROFILE\nas-index.csv"          # preview
    .\Restore-FromNAS.ps1 -IndexPath "$env:USERPROFILE\nas-index.csv" -Execute # do it

.PARAMETER Filter
    Optional wildcard to restore only a subset, matched against SourcePath,
    e.g.  -Filter '*\Downloads\*'  or  -Filter '*.iso'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $IndexPath,
    [string] $Filter = '*',
    [string] $LogPath = "$env:USERPROFILE\nas-restore.log",
    [switch] $Execute
)

$ErrorActionPreference = 'Stop'
function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 's'), $Level, $Message
    Write-Host $line; Add-Content -LiteralPath $LogPath -Value $line
}

if (-not (Test-Path -LiteralPath $IndexPath)) { throw "Index not found: $IndexPath" }
$rows = Import-Csv -LiteralPath $IndexPath

$restorable = $rows | Where-Object {
    $_.Status -in @('MOVED','MOVED-FAST','MOVED-DEDUP','COPIED') -and
    $_.SourcePath -like $Filter
}

Write-Log "=== Restore start | rows=$($restorable.Count) | DryRun=$([bool](-not $Execute)) ==="
$ok=0; $err=0

# Restore most-recent first so collision suffixes unwind cleanly.
foreach ($r in ($restorable | Sort-Object Timestamp -Descending)) {
    $src = $r.TargetPath   # currently on the NAS
    $dst = $r.SourcePath   # original location
    try {
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Log "MISSING on NAS, skipping: $src" 'WARN'; continue
        }
        if (-not $Execute) { Write-Log "DRYRUN  $src  ->  $dst"; $ok++; continue }

        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

        $finalDst = $dst
        if (Test-Path -LiteralPath $finalDst) {
            $b = [IO.Path]::GetFileNameWithoutExtension($dst); $e = [IO.Path]::GetExtension($dst)
            $finalDst = Join-Path $dstDir ("{0}_restored{1}" -f $b, $e)
        }

        Copy-Item -LiteralPath $src -Destination $finalDst -Force
        if ($r.SHA256) {
            $h = (Get-FileHash -LiteralPath $finalDst -Algorithm SHA256).Hash
            if ($h -ne $r.SHA256) { Remove-Item -LiteralPath $finalDst -Force -EA SilentlyContinue; throw "Hash mismatch restoring $src" }
        }
        Remove-Item -LiteralPath $src -Force
        Write-Log "RESTORED  $src  ->  $finalDst"; $ok++
    }
    catch { $err++; Write-Log "ERROR  $src :: $($_.Exception.Message)" 'ERROR' }
}

Write-Log "=== Restore done | ok=$ok errors=$err ==="
if (-not $Execute) { Write-Log "DRY RUN only. Re-run with -Execute to apply." 'WARN' }
