# NAS Organizer

PowerShell toolkit to free space on `C:` by sorting files into categorized
folders on the NAS (drives **M: / P: / R:**), keeping a full **source→target
index** so every move can be located or reversed.

> Run these on your **Windows machine** (PowerShell 5.1+ or PowerShell 7).
> They were authored in a remote container and cannot touch your drives on
> their own.

## Quick start

```powershell
# 1) PREVIEW — touches nothing, writes a planned index you can eyeball
.\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads','C:\Users\me\Videos'

# 2) APPLY — copy -> verify SHA256 -> delete source, logging every move
.\Organize-ToNAS.ps1 -SourcePaths 'C:\Users\me\Downloads','C:\Users\me\Videos' -Execute
```

## How files are routed

| Drive | Category | Sub-categories |
|-------|----------|----------------|
| **M:** | Media | Video, Audio, Images, Images\RAW |
| **P:** | Documents / Projects | PDF, Office, Ebooks, Code |
| **R:** | Archives / Systems | Archives, Disk-Images, Installers, Backups, Misc\<ext> |

Edit the `$CategoryMap` hashtable at the top of `Organize-ToNAS.ps1` to change
any mapping. Unknown extensions land in `R:\Misc\<ext>`.

## The index (`%USERPROFILE%\nas-index.csv`)

One row per file action:

`Timestamp, Mode, DryRun, Status, Category, SubCategory, SizeBytes, SHA256, SourcePath, TargetPath`

- **Locate** a file: open the CSV and search by name/category.
- **Reverse** a run: feed the CSV to `Restore-FromNAS.ps1`.

```powershell
.\Restore-FromNAS.ps1 -IndexPath "$env:USERPROFILE\nas-index.csv"            # preview
.\Restore-FromNAS.ps1 -IndexPath "$env:USERPROFILE\nas-index.csv" -Execute   # restore
.\Restore-FromNAS.ps1 -IndexPath "$env:USERPROFILE\nas-index.csv" -Filter '*.iso' -Execute
```

## Modes

| `-Mode` | Behaviour |
|---------|-----------|
| `SafeMove` (default) | Copy → verify SHA256 → delete source. Safest. |
| `MoveFast` | `robocopy /MOVE`. Faster, no post-verify. |
| `CopyOnly` | Copy to NAS, leave source in place. |

## Safety notes

- **Dry run by default.** Nothing changes until you pass `-Execute`.
- **HuggingFace is excluded** (`D:\hf_cache`, `*\.cache\huggingface\*`) so this
  won't collide with the agent populating `HF_HOME=D:\hf_cache`.
- `-MinSizeBytes` (default 1 MB) skips tiny files — tune as needed.
- Point `-SourcePaths` at specific space hogs. **Do not** point it at all of
  `C:\` (it would try to move system/Program Files).
- Identical files already on the NAS are de-duplicated, so re-runs are safe.

## Suggested first targets for reclaiming space

```powershell
# Find your biggest folders first:
Get-ChildItem C:\Users\$env:USERNAME -Directory |
  ForEach-Object { [pscustomobject]@{ Folder=$_.FullName
    GB = '{0:N1}' -f ((Get-ChildItem $_.FullName -Recurse -File -EA SilentlyContinue |
         Measure-Object Length -Sum).Sum / 1GB) } } |
  Sort-Object {[double]$_.GB} -Descending | Format-Table -Auto
```
