#!/usr/bin/env python3
"""Create a source-only handoff archive using an explicit allowlist."""
from pathlib import Path
import hashlib
import zipfile

root = Path(__file__).resolve().parent.parent
entries = [
    "README.md", "THIRD_PARTY_NOTICES.md", "实施方案-免本机Xcode.md",
    "Package.swift", "project.yml", ".gitignore", ".github",
    "VoiceBench.xcodeproj", "VoiceBench", "Sources", "Tests", "scripts",
    "config", "licenses", "docs",
]
output = root / "build" / "VoiceBench-source.zip"
output.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for entry in entries:
        path = root / entry
        if not path.exists():
            raise FileNotFoundError(path)
        files = sorted(path.rglob("*")) if path.is_dir() else [path]
        for file in files:
            if not file.is_file() or file.is_symlink():
                continue
            if any(part in {"xcuserdata", "__pycache__", ".DS_Store"} for part in file.parts):
                continue
            archive.write(file, "VoiceBench/" + file.relative_to(root).as_posix())
with zipfile.ZipFile(output) as archive:
    if archive.testzip() is not None:
        raise RuntimeError("Archive verification failed")
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(".zip.sha256").write_text(f"{digest}  {output.name}\n")
print(f"Verified source archive: {output} ({output.stat().st_size:,} bytes)")
