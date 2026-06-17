#!/usr/bin/env python3
"""Dry-run self-test of the NAS organizer routing logic.
Mirrors the $CategoryMap in Organize-ToNAS.ps1. Categorizes whatever files it
is pointed at and writes the same index CSV format. DRY RUN ONLY: it never
copies, moves, or deletes anything. Used here to validate routing on the
container's own files, since the Windows C:/M:/P:/R: drives are not reachable
from this cloud session.
"""
import csv, hashlib, os, sys, datetime

CATEGORY_MAP = {
    # M: Media
    **{e: "M:Media\\Video"  for e in (".mp4",".mkv",".avi",".mov",".wmv",".flv",".webm",".m4v",".mpg",".mpeg")},
    **{e: "M:Media\\Audio"  for e in (".mp3",".flac",".wav",".aac",".ogg",".m4a",".wma")},
    **{e: "M:Media\\Images" for e in (".jpg",".jpeg",".png",".gif",".bmp",".tiff",".heic",".webp",".svg")},
    **{e: "M:Media\\Images\\RAW" for e in (".cr2",".nef",".arw",".dng")},
    # P: Documents & Projects
    ".pdf": "P:Documents\\PDF",
    **{e: "P:Documents\\Office" for e in (".doc",".docx",".rtf",".xls",".xlsx",".csv",".ppt",".pptx",".odt",".ods",".txt")},
    ".md": "P:Documents\\Notes",
    **{e: "P:Documents\\Ebooks" for e in (".epub",".mobi",".azw3")},
    **{e: "P:Projects\\Code"    for e in (".py",".js",".ts",".java",".c",".cpp",".cs",".go",".rs",".rb",".php",".html",".css",".json",".xml",".yaml",".yml",".sql",".sh",".ps1",".ipynb")},
    # R: Archives / Systems
    **{e: "R:Archives"    for e in (".zip",".rar",".7z",".tar",".gz",".bz2",".xz")},
    **{e: "R:Disk-Images" for e in (".iso",".img",".vhd",".vhdx")},
    **{e: "R:Installers"  for e in (".exe",".msi",".msix",".appx")},
    **{e: "R:Backups"     for e in (".bak",".bkf",".vbk")},
}
DEFAULT_ROOT = "R:Misc"

def route(ext):
    spec = CATEGORY_MAP.get(ext.lower(), f"{DEFAULT_ROOT}\\{(ext.lstrip('.') or 'no-ext')}")
    drive, rel = spec[:2], spec[2:].lstrip("\\")
    cat, _, sub = rel.partition("\\")
    return drive, cat, sub, f"{drive}\\{rel}"

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest().upper()

def main(sources, index_path):
    rows = []
    for root in sources:
        for dirpath, _, files in os.walk(root):
            for name in files:
                full = os.path.join(dirpath, name)
                ext = os.path.splitext(name)[1]
                drive, cat, sub, target_dir = route(ext)
                size = os.path.getsize(full)
                rows.append({
                    "Timestamp": datetime.datetime.now().isoformat(timespec="seconds"),
                    "Mode": "SafeMove", "DryRun": "True", "Status": "PLANNED",
                    "Category": cat, "SubCategory": sub, "SizeBytes": size,
                    "SHA256": sha256(full),
                    "SourcePath": full,
                    "TargetPath": os.path.join(target_dir, name).replace("/", "\\"),
                })
    with open(index_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    # console summary
    print(f"{'SOURCE':<55} -> TARGET")
    print("-" * 100)
    for r in rows:
        print(f"{os.path.basename(r['SourcePath']):<55} -> {r['TargetPath']}")
    print("-" * 100)
    from collections import Counter
    by_drive = Counter(r["TargetPath"][:2] for r in rows)
    print("Files per NAS drive:", dict(by_drive))
    print(f"Index written: {index_path} ({len(rows)} rows)")

if __name__ == "__main__":
    srcs = sys.argv[1:] or ["/home/user/Database"]
    main(srcs, "/home/user/Database/nas-organizer/nas-index.demo.csv")
