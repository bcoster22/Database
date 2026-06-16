<#
.SYNOPSIS
    Free space on C: by sorting files into categorized folders on the NAS
    (drives M:, P:, R:), with a full source->target index for locating/reversing.

.DESCRIPTION
    For every file under -SourcePaths the script:
      1. Determines a Category / SubCategory from its extension (see $CategoryMap).
      2. Builds a target path on the mapped NAS drive.
      3. Copies the file, verifies it (SHA256), then deletes the source  (default,
         "safe move"). Other modes: MoveFast (robocopy /MOVE) or CopyOnly.
      4. Appends a row to the index CSV so any move can be located or reversed.

    SAFE BY DEFAULT: runs as a DRY RUN. Nothing is copied or deleted until you
    add  -Execute .

.EXAMPLE
    # See exactly what WOULD happen, write a preview index, touch nothing:
    .\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads','C:\Users\me\Videos'

.EXAMPLE
    # Actually do it (copy -> verify -> delete), logging every move:
    .\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads' -Execute

.NOTES
    Reverse any run with Restore-FromNAS.ps1 using the produced index CSV.
#>

[CmdletBinding()]
param(
    # Folders to organize. Point these at the space hogs, NOT the whole of C:.
    [string[]] $SourcePaths = @("$env:USERPROFILE\Downloads"),

    # Where to write/append the index. One row per file action.
    [string]   $IndexPath = "$env:USERPROFILE\nas-index.csv",

    # Log file (human-readable transcript).
    [string]   $LogPath = "$env:USERPROFILE\nas-organizer.log",

    # SafeMove = copy+verify(SHA256)+delete | MoveFast = robocopy /MOVE | CopyOnly = keep source
    [ValidateSet('SafeMove','MoveFast','CopyOnly')]
    [string]   $Mode = 'SafeMove',

    # Only move files at least this big (bytes). 0 = move everything. Default 1 MB.
    [long]     $MinSizeBytes = 1MB,

    # Paths to never touch (HuggingFace cache is handled by another agent).
    [string[]] $ExcludePaths = @('D:\hf_cache', '*\.cache\huggingface\*', '*\AppData\Local\Temp\*'),

    # Actually perform actions. Omit for a dry run.
    [switch]   $Execute
)

# ----------------------------------------------------------------------------
#  CATEGORY MAP  -- edit freely. Key = lower-case extension (with the dot).
#  Value = @{ Drive='M:'; Category='Media'; Sub='Video' }
# ----------------------------------------------------------------------------
$CategoryMap = @{
    # --- M:  Media -----------------------------------------------------------
    '.mp4'='M:Media\Video'; '.mkv'='M:Media\Video'; '.avi'='M:Media\Video';
    '.mov'='M:Media\Video'; '.wmv'='M:Media\Video'; '.flv'='M:Media\Video';
    '.webm'='M:Media\Video'; '.m4v'='M:Media\Video'; '.mpg'='M:Media\Video'; '.mpeg'='M:Media\Video';

    '.mp3'='M:Media\Audio'; '.flac'='M:Media\Audio'; '.wav'='M:Media\Audio';
    '.aac'='M:Media\Audio'; '.ogg'='M:Media\Audio'; '.m4a'='M:Media\Audio'; '.wma'='M:Media\Audio';

    '.jpg'='M:Media\Images'; '.jpeg'='M:Media\Images'; '.png'='M:Media\Images';
    '.gif'='M:Media\Images'; '.bmp'='M:Media\Images'; '.tiff'='M:Media\Images';
    '.heic'='M:Media\Images'; '.webp'='M:Media\Images'; '.svg'='M:Media\Images';
    '.cr2'='M:Media\Images\RAW'; '.nef'='M:Media\Images\RAW'; '.arw'='M:Media\Images\RAW'; '.dng'='M:Media\Images\RAW';

    # --- P:  Documents & Projects -------------------------------------------
    '.pdf'='P:Documents\PDF';
    '.doc'='P:Documents\Office'; '.docx'='P:Documents\Office'; '.rtf'='P:Documents\Office';
    '.xls'='P:Documents\Office'; '.xlsx'='P:Documents\Office'; '.csv'='P:Documents\Office';
    '.ppt'='P:Documents\Office'; '.pptx'='P:Documents\Office';
    '.odt'='P:Documents\Office'; '.ods'='P:Documents\Office'; '.txt'='P:Documents\Office';
    '.epub'='P:Documents\Ebooks'; '.mobi'='P:Documents\Ebooks'; '.azw3'='P:Documents\Ebooks';

    '.py'='P:Projects\Code'; '.js'='P:Projects\Code'; '.ts'='P:Projects\Code';
    '.java'='P:Projects\Code'; '.c'='P:Projects\Code'; '.cpp'='P:Projects\Code';
    '.cs'='P:Projects\Code'; '.go'='P:Projects\Code'; '.rs'='P:Projects\Code';
    '.rb'='P:Projects\Code'; '.php'='P:Projects\Code'; '.html'='P:Projects\Code';
    '.css'='P:Projects\Code'; '.json'='P:Projects\Code'; '.xml'='P:Projects\Code';
    '.yaml'='P:Projects\Code'; '.yml'='P:Projects\Code'; '.sql'='P:Projects\Code';
    '.sh'='P:Projects\Code'; '.ps1'='P:Projects\Code'; '.ipynb'='P:Projects\Code';

    # --- R:  Archives / Systems / Misc --------------------------------------
    '.zip'='R:Archives'; '.rar'='R:Archives'; '.7z'='R:Archives';
    '.tar'='R:Archives'; '.gz'='R:Archives'; '.bz2'='R:Archives'; '.xz'='R:Archives';

    '.iso'='R:Disk-Images'; '.img'='R:Disk-Images'; '.vhd'='R:Disk-Images'; '.vhdx'='R:Disk-Images';

    '.exe'='R:Installers'; '.msi'='R:Installers'; '.msix'='R:Installers'; '.appx'='R:Installers';

    '.bak'='R:Backups'; '.bkf'='R:Backups'; '.vbk'='R:Backups';
}
# Anything not in the map -> R:\Misc\<ext>
$DefaultRoot = 'R:Misc'

# ----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 's'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Resolve-Target {
    param([System.IO.FileInfo]$File)
    $ext = $File.Extension.ToLowerInvariant()
    if ($CategoryMap.ContainsKey($ext)) {
        $spec = $CategoryMap[$ext]                       # e.g. 'M:Media\Video'
    } else {
        $subExt = if ($ext) { $ext.TrimStart('.') } else { 'no-ext' }
        $spec = "$DefaultRoot\$subExt"
    }
    $drive  = $spec.Substring(0,2)                        # 'M:'
    $relDir = $spec.Substring(2).TrimStart('\')           # 'Media\Video'
    $parts  = $relDir -split '\\', 2
    $category = $parts[0]
    $subCategory = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    [pscustomobject]@{
        Drive       = $drive
        Category    = $category
        SubCategory = $subCategory
        TargetDir   = Join-Path "$drive\" $relDir
    }
}

function Get-UniqueTarget {
    param([string]$TargetDir, [System.IO.FileInfo]$File)
    $base = [IO.Path]::GetFileNameWithoutExtension($File.Name)
    $ext  = $File.Extension
    $candidate = Join-Path $TargetDir $File.Name
    $i = 0
    while (Test-Path -LiteralPath $candidate) {
        # If an identical file is already there, reuse it (idempotent re-runs).
        try {
            if ((Get-Item -LiteralPath $candidate).Length -eq $File.Length -and
                (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -eq
                (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash) {
                return @{ Path = $candidate; AlreadyThere = $true }
            }
        } catch { }
        $i++
        $candidate = Join-Path $TargetDir ("{0}_{1}{2}" -f $base, $i, $ext)
    }
    return @{ Path = $candidate; AlreadyThere = $false }
}

function Test-Excluded {
    param([string]$Path)
    foreach ($pat in $ExcludePaths) {
        if ($Path -like $pat) { return $true }
        if ($Path -like ($pat.TrimEnd('*') + '*')) { return $true }
    }
    return $false
}

# --- Index setup ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $IndexPath)) {
    'Timestamp,Mode,DryRun,Status,Category,SubCategory,SizeBytes,SHA256,SourcePath,TargetPath' |
        Set-Content -LiteralPath $IndexPath -Encoding UTF8
}
function Add-IndexRow {
    param($Status,$Cat,$Sub,$Size,$Hash,$Src,$Tgt)
    $esc = { param($v) '"' + ($v -replace '"','""') + '"' }
    $row = @(
        (Get-Date -Format 's'), $Mode, (-not $Execute), $Status, (& $esc $Cat),
        (& $esc $Sub), $Size, $Hash, (& $esc $Src), (& $esc $Tgt)
    ) -join ','
    Add-Content -LiteralPath $IndexPath -Value $row -Encoding UTF8
}

# --- Main -------------------------------------------------------------------
Write-Log "=== Organize-ToNAS start | Mode=$Mode | DryRun=$([bool](-not $Execute)) | Min=$MinSizeBytes B ==="
Write-Log "Sources: $($SourcePaths -join '; ')"

$stats = [ordered]@{ Scanned=0; Moved=0; Skipped=0; Errors=0; BytesMoved=[long]0 }

foreach ($root in $SourcePaths) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Log "Source not found: $root" 'WARN'; continue }

    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $file = $_
        $stats.Scanned++
        try {
            if (Test-Excluded $file.FullName) { $stats.Skipped++; return }
            if ($file.Length -lt $MinSizeBytes) { $stats.Skipped++; return }

            $t = Resolve-Target -File $file

            if ($Execute) {
                if (-not (Test-Path -LiteralPath $t.TargetDir)) {
                    New-Item -ItemType Directory -Path $t.TargetDir -Force | Out-Null
                }
            }
            $dest = Get-UniqueTarget -TargetDir $t.TargetDir -File $file
            $targetPath = $dest.Path

            if (-not $Execute) {
                Write-Log "DRYRUN  $($file.FullName)  ->  $targetPath"
                Add-IndexRow 'PLANNED' $t.Category $t.SubCategory $file.Length '' $file.FullName $targetPath
                $stats.Moved++; return
            }

            switch ($Mode) {
                'SafeMove' {
                    if ($dest.AlreadyThere) {
                        Remove-Item -LiteralPath $file.FullName -Force
                        $hash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                        Add-IndexRow 'MOVED-DEDUP' $t.Category $t.SubCategory $file.Length $hash $file.FullName $targetPath
                    } else {
                        $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
                        $dstHash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                        if ($srcHash -ne $dstHash) {
                            Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue
                            throw "Hash mismatch after copy (source kept): $($file.FullName)"
                        }
                        Remove-Item -LiteralPath $file.FullName -Force
                        Add-IndexRow 'MOVED' $t.Category $t.SubCategory $file.Length $dstHash $file.FullName $targetPath
                    }
                }
                'CopyOnly' {
                    $srcHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                    Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
                    Add-IndexRow 'COPIED' $t.Category $t.SubCategory $file.Length $srcHash $file.FullName $targetPath
                }
                'MoveFast' {
                    $rc = robocopy $file.DirectoryName $t.TargetDir $file.Name /MOVE /NJH /NJS /NP /R:1 /W:1
                    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE) for $($file.FullName)" }
                    Add-IndexRow 'MOVED-FAST' $t.Category $t.SubCategory $file.Length '' $file.FullName $targetPath
                }
            }
            Write-Log "$Mode  $($file.FullName)  ->  $targetPath"
            $stats.Moved++; $stats.BytesMoved += $file.Length
        }
        catch {
            $stats.Errors++
            Write-Log "ERROR  $($file.FullName) :: $($_.Exception.Message)" 'ERROR'
            Add-IndexRow 'ERROR' '' '' $file.Length '' $file.FullName ''
        }
    }
}

Write-Log ("=== Done | Scanned={0} Moved/Planned={1} Skipped={2} Errors={3} Freed={4:N1} GB ===" -f `
    $stats.Scanned, $stats.Moved, $stats.Skipped, $stats.Errors, ($stats.BytesMoved/1GB))
Write-Log "Index : $IndexPath"
if (-not $Execute) { Write-Log "This was a DRY RUN. Re-run with -Execute to apply." 'WARN' }
