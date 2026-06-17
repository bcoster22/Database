# NAS Migration — Requirements

> Agreed 2026-06-17. This is the authoritative spec; the scripts implement it.

## Goal
Free space on **C:** by moving files to the NAS (drives **M:**, **P:**, **R:**),
keeping a reversible **source→target index** so anything can be located or put back.
A separate agent owns HuggingFace files (`HF_HOME=D:\hf_cache`) — out of scope, excluded.

## 1. Where things go (NAS layout) — *by type*
| Drive | Holds | Categories |
|-------|-------|-----------|
| **M:** | Media | Video, Audio, Images (RAW broken out) |
| **P:** | Documents & Projects | PDF, Office, Ebooks, Code, Notes(`.md`) |
| **R:** | Archives & Systems | Archives, Disk-Images, Installers, Backups, Misc |

## 2. What to move (sources on C:)
First **find where the space is actually used**, then target:
- `C:\Users\<me>\Downloads`
- `C:\Users\<me>\Videos`, `\Music`, `\Pictures`
- `C:\Users\<me>\Documents`
- A **scan of C:** for the biggest / least-recently-used files, proposed for review.

→ Implemented as a read-only **Scan-Report** (top folders + biggest/oldest files)
that runs *before* any move so we move from evidence, not guesses.

## 3. How to move — *Fast move*
- `robocopy /MOVE` (moves then removes source).
- Per-file row still written to the index (source, target, size, date, status).
- **Dry-run by default**; real move only with `-Execute`.

## 4. Folder arrangement within a category — *destination-aware*
The key requirement: **don't impose a blind structure — match what the NAS already does.**
For each file's target category folder, the tool will:
1. **Inspect the existing subfolders** on the NAS under that category.
2. **Detect the convention in use:**
   - Date folders `YYYY`, `YYYY-MM`, or `YYYY-MM-DD` → place by the **file's modified date**.
   - Named folders that match the file's **source subfolder** → reuse that folder.
   - No clear convention → place directly in the category root (flat).
3. **Create missing folders** as needed (e.g. a new `2026` year folder).

## 5. Index & reversibility
- CSV: `Timestamp, Mode, DryRun, Status, Category, SubCategory, SizeBytes, Modified, SHA256?, SourcePath, TargetPath`.
- `Restore-FromNAS.ps1` reverses any run from the index.

## 6. Safety / exclusions
- Skip `.git`, hidden & system folders, in-use/locked files.
- Skip HuggingFace: `D:\hf_cache`, `*\.cache\huggingface\*`.
- Min size filter (default 1 MB) to ignore clutter.
- Idempotent: identical file already on NAS is de-duplicated, re-runs are safe.

## 7. Hard constraint (environment)
The scripts must run **on the Windows machine** (Claude Code desktop/CLI, or handed to
the local agent). This cloud session has no access to C:/M:/P:/R:, so it authors and
validates the tooling but cannot perform the live move itself.

## Open items needing your input
- [ ] Confirm your Windows **username** / exact source paths (or let Scan-Report find them).
- [ ] Confirm `.md` → `P:\Documents\Notes` is desired (vs Office).
- [ ] Any file types or folders to explicitly **never** move?
