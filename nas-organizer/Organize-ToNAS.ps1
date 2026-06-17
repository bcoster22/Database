<#
.SYNOPSIS
    Move files off C: onto the NAS (M:/P:/R:), routing by type and placing each
    file to MATCH THE DESTINATION'S EXISTING FOLDER CONVENTION (date or named),
    creating missing folders. Keeps a reversible source->target index.

.DESCRIPTION
    Per file:
      1. Route to a NAS category root by extension      (see $CategoryMap).
      2. Inspect that root on the NAS and detect its convention:
           - date folders  YYYY | YYYY-MM | YYYY-MM-DD  -> place by file's modified date
           - named folders matching the source subfolder -> reuse it
           - otherwise                                    -> category root (flat)
         Missing folders are created.
      3. Move via robocopy /MOVE  (Mode=MoveFast, default) or copy+verify+delete.
      4. Append a row to the index CSV.

    DRY RUN by default. Nothing changes until you pass -Execute.

.EXAMPLE
    .\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads'              # preview
    .\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads' -Execute     # do it
#>
[CmdletBinding()]
param(
    [string[]] $SourcePaths = @("$env:USERPROFILE\Downloads"),
    [string]   $IndexPath   = "$env:USERPROFILE\nas-index.csv",
    [string]   $LogPath     = "$env:USERPROFILE\nas-organizer.log",
    [ValidateSet('MoveFast','SafeMove','CopyOnly')]
    [string]   $Mode        = 'MoveFast',
    [long]     $MinSizeBytes = 1MB,
    [string[]] $ExcludePaths = @('D:\hf_cache','*\.cache\huggingface\*','*\AppData\Local\Temp\*'),
    [switch]   $Execute
)

# --- Category map: extension -> 'DRIVE:Category\Sub' -------------------------
$CategoryMap = @{
    '.mp4'='M:Media\Video';'.mkv'='M:Media\Video';'.avi'='M:Media\Video';'.mov'='M:Media\Video'
    '.wmv'='M:Media\Video';'.flv'='M:Media\Video';'.webm'='M:Media\Video';'.m4v'='M:Media\Video'
    '.mpg'='M:Media\Video';'.mpeg'='M:Media\Video'
    '.mp3'='M:Media\Audio';'.flac'='M:Media\Audio';'.wav'='M:Media\Audio';'.aac'='M:Media\Audio'
    '.ogg'='M:Media\Audio';'.m4a'='M:Media\Audio';'.wma'='M:Media\Audio'
    '.jpg'='M:Media\Images';'.jpeg'='M:Media\Images';'.png'='M:Media\Images';'.gif'='M:Media\Images'
    '.bmp'='M:Media\Images';'.tiff'='M:Media\Images';'.heic'='M:Media\Images';'.webp'='M:Media\Images';'.svg'='M:Media\Images'
    '.cr2'='M:Media\Images\RAW';'.nef'='M:Media\Images\RAW';'.arw'='M:Media\Images\RAW';'.dng'='M:Media\Images\RAW'
    '.pdf'='P:Documents\PDF'
    '.doc'='P:Documents\Office';'.docx'='P:Documents\Office';'.rtf'='P:Documents\Office'
    '.xls'='P:Documents\Office';'.xlsx'='P:Documents\Office';'.csv'='P:Documents\Office'
    '.ppt'='P:Documents\Office';'.pptx'='P:Documents\Office';'.odt'='P:Documents\Office';'.ods'='P:Documents\Office';'.txt'='P:Documents\Office'
    '.md'='P:Documents\Notes'
    '.epub'='P:Documents\Ebooks';'.mobi'='P:Documents\Ebooks';'.azw3'='P:Documents\Ebooks'
    '.py'='P:Projects\Code';'.js'='P:Projects\Code';'.ts'='P:Projects\Code';'.java'='P:Projects\Code'
    '.c'='P:Projects\Code';'.cpp'='P:Projects\Code';'.cs'='P:Projects\Code';'.go'='P:Projects\Code'
    '.rs'='P:Projects\Code';'.rb'='P:Projects\Code';'.php'='P:Projects\Code';'.html'='P:Projects\Code'
    '.css'='P:Projects\Code';'.json'='P:Projects\Code';'.xml'='P:Projects\Code';'.yaml'='P:Projects\Code'
    '.yml'='P:Projects\Code';'.sql'='P:Projects\Code';'.sh'='P:Projects\Code';'.ps1'='P:Projects\Code';'.ipynb'='P:Projects\Code'
    '.zip'='R:Archives';'.rar'='R:Archives';'.7z'='R:Archives';'.tar'='R:Archives';'.gz'='R:Archives';'.bz2'='R:Archives';'.xz'='R:Archives'
    '.iso'='R:Disk-Images';'.img'='R:Disk-Images';'.vhd'='R:Disk-Images';'.vhdx'='R:Disk-Images'
    '.exe'='R:Installers';'.msi'='R:Installers';'.msix'='R:Installers';'.appx'='R:Installers'
    '.bak'='R:Backups';'.bkf'='R:Backups';'.vbk'='R:Backups'
}
$DefaultRoot = 'R:Misc'

$ErrorActionPreference = 'Stop'
function Write-Log { param($m,$lvl='INFO')
    $l='{0} [{1}] {2}' -f (Get-Date -Format s),$lvl,$m; Write-Host $l; Add-Content -LiteralPath $LogPath $l }

# Route extension -> @{ Drive; Category; Sub; Root }  (Root = full category dir)
function Resolve-Category { param([System.IO.FileInfo]$f)
    $ext=$f.Extension.ToLowerInvariant()
    $spec = if($CategoryMap.ContainsKey($ext)){$CategoryMap[$ext]}
            else { "$DefaultRoot\$(if($ext){$ext.TrimStart('.')}else{'no-ext'})" }
    $drive=$spec.Substring(0,2); $rel=$spec.Substring(2).TrimStart('\')
    $p=$rel -split '\\',2
    [pscustomobject]@{ Drive=$drive; Category=$p[0]; Sub=($p[1]); Root=(Join-Path "$drive\" $rel) }
}

# Look at what the NAS already does under a category root.
function Get-DestinationConvention { param([string]$root)
    if(-not (Test-Path -LiteralPath $root)){ return 'none' }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -Expand Name)
    if($dirs.Count -eq 0){ return 'flat' }
    $y=0;$ym=0;$ymd=0
    foreach($d in $dirs){
        if    ($d -match '^\d{4}$')                 {$y++}
        elseif($d -match '^\d{4}[-_]\d{2}$')        {$ym++}
        elseif($d -match '^\d{4}[-_]\d{2}[-_]\d{2}$'){$ymd++}
    }
    $t=$dirs.Count
    if($ymd/$t -ge .5){return 'ymd'}
    if($ym /$t -ge .5){return 'ym'}
    if($y  /$t -ge .5){return 'year'}
    return 'named'
}

# Decide the final folder for a file, honouring the destination's convention.
function Resolve-Placement { param([string]$root,[System.IO.FileInfo]$f)
    $conv = Get-DestinationConvention $root
    $date = $f.LastWriteTime
    switch($conv){
        'year' { return @{ Dir=(Join-Path $root $date.ToString('yyyy'));        Why="date/year ($conv)" } }
        'ym'   { return @{ Dir=(Join-Path $root $date.ToString('yyyy-MM'));      Why="date/month ($conv)" } }
        'ymd'  { return @{ Dir=(Join-Path $root $date.ToString('yyyy-MM-dd'));   Why="date/day ($conv)" } }
        'named'{
            $srcParent = Split-Path $f.DirectoryName -Leaf
            $cand = Join-Path $root $srcParent
            if(Test-Path -LiteralPath $cand){ return @{ Dir=$cand; Why="reuse named '$srcParent'" } }
            return @{ Dir=$root; Why='named root (no match)' }
        }
        default{ return @{ Dir=$root; Why=$conv } }   # flat / none
    }
}

function Get-UniqueTarget { param([string]$dir,[System.IO.FileInfo]$f)
    $b=[IO.Path]::GetFileNameWithoutExtension($f.Name); $e=$f.Extension
    $c=Join-Path $dir $f.Name; $i=0
    while(Test-Path -LiteralPath $c){
        try{ if((Get-Item -LiteralPath $c).Length -eq $f.Length){ return @{Path=$c;Dupe=$true} } }catch{}
        $i++; $c=Join-Path $dir ("{0}_{1}{2}" -f $b,$i,$e)
    }
    @{Path=$c;Dupe=$false}
}

function Test-Excluded { param([System.IO.FileInfo]$f)
    $p=$f.FullName
    foreach($pat in $ExcludePaths){ if($p -like $pat -or $p -like ($pat.TrimEnd('*')+'*')){return $true} }
    if($p -match '(\\|/)\.git(\\|/|$)'){ return $true }
    $a=$f.Attributes
    if(($a -band [IO.FileAttributes]::Hidden) -or ($a -band [IO.FileAttributes]::System)){ return $true }
    return $false
}

if(-not (Test-Path -LiteralPath $IndexPath)){
    'Timestamp,Mode,DryRun,Status,Category,SubCategory,Convention,SizeBytes,Modified,SHA256,SourcePath,TargetPath' |
        Set-Content -LiteralPath $IndexPath -Encoding UTF8
}
function Add-IndexRow { param($Status,$Cat,$Sub,$Conv,$Size,$Mod,$Hash,$Src,$Tgt)
    $q={param($v) '"'+(($v -as [string]) -replace '"','""')+'"'}
    (@((Get-Date -Format s),$Mode,(-not $Execute),$Status,(&$q $Cat),(&$q $Sub),(&$q $Conv),
       $Size,$Mod,$Hash,(&$q $Src),(&$q $Tgt)) -join ',') |
        Add-Content -LiteralPath $IndexPath -Encoding UTF8
}

Write-Log "=== Organize start | Mode=$Mode | DryRun=$([bool](-not $Execute)) | Min=$MinSizeBytes ==="
Write-Log "Sources: $($SourcePaths -join '; ')"
$st=[ordered]@{Scanned=0;Moved=0;Skipped=0;Errors=0;Bytes=[long]0}

foreach($root in $SourcePaths){
    if(-not (Test-Path -LiteralPath $root)){ Write-Log "Source not found: $root" WARN; continue }
    Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $f=$_; $st.Scanned++
        try{
            if(Test-Excluded $f){ $st.Skipped++; return }
            if($f.Length -lt $MinSizeBytes){ $st.Skipped++; return }

            $cat = Resolve-Category $f
            $place = Resolve-Placement $cat.Root $f
            $mod = $f.LastWriteTime.ToString('yyyy-MM-dd')

            if(-not $Execute){
                $dest = Get-UniqueTarget $place.Dir $f
                Write-Log "DRYRUN [$($place.Why)] $($f.FullName) -> $($dest.Path)"
                Add-IndexRow 'PLANNED' $cat.Category $cat.Sub $place.Why $f.Length $mod '' $f.FullName $dest.Path
                $st.Moved++; return
            }

            if(-not (Test-Path -LiteralPath $place.Dir)){ New-Item -ItemType Directory -Path $place.Dir -Force | Out-Null }
            $dest = Get-UniqueTarget $place.Dir $f
            $target=$dest.Path

            switch($Mode){
                'MoveFast'{
                    $name = Split-Path $target -Leaf
                    robocopy $f.DirectoryName (Split-Path $target -Parent) $f.Name /MOV /NJH /NJS /NP /R:1 /W:1 | Out-Null
                    if($LASTEXITCODE -ge 8){ throw "robocopy exit $LASTEXITCODE" }
                    if($name -ne $f.Name -and (Test-Path -LiteralPath (Join-Path (Split-Path $target -Parent) $f.Name))){
                        Move-Item -LiteralPath (Join-Path (Split-Path $target -Parent) $f.Name) -Destination $target -Force
                    }
                    Add-IndexRow 'MOVED' $cat.Category $cat.Sub $place.Why $f.Length $mod '' $f.FullName $target
                }
                'SafeMove'{
                    $sh=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                    Copy-Item -LiteralPath $f.FullName -Destination $target -Force
                    if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $sh){
                        Remove-Item -LiteralPath $target -Force -EA SilentlyContinue; throw "hash mismatch (source kept)" }
                    Remove-Item -LiteralPath $f.FullName -Force
                    Add-IndexRow 'MOVED' $cat.Category $cat.Sub $place.Why $f.Length $mod $sh $f.FullName $target
                }
                'CopyOnly'{
                    Copy-Item -LiteralPath $f.FullName -Destination $target -Force
                    Add-IndexRow 'COPIED' $cat.Category $cat.Sub $place.Why $f.Length $mod '' $f.FullName $target
                }
            }
            Write-Log "$Mode [$($place.Why)] $($f.FullName) -> $target"
            $st.Moved++; $st.Bytes+=$f.Length
        }catch{
            $st.Errors++; Write-Log "ERROR $($f.FullName) :: $($_.Exception.Message)" ERROR
            Add-IndexRow 'ERROR' '' '' '' $f.Length '' '' $f.FullName ''
        }
    }
}

Write-Log ("=== Done | Scanned={0} Moved/Planned={1} Skipped={2} Errors={3} Freed={4:N1} GB ===" -f `
    $st.Scanned,$st.Moved,$st.Skipped,$st.Errors,($st.Bytes/1GB))
Write-Log "Index: $IndexPath"
if(-not $Execute){ Write-Log "DRY RUN. Re-run with -Execute to apply." WARN }
