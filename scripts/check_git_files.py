#!/usr/bin/env python3
"""Reject generated binaries and large files already staged/tracked by Git."""
from pathlib import PurePosixPath
import subprocess

limit = 10 * 1024 * 1024
excluded = {"Models", "Vendor", ".downloads", ".tools", ".build", ".build-local", "build"}
rows = subprocess.check_output(["git", "ls-files", "--stage", "-z"]).split(b"\0")
count = total = largest = 0
for row in filter(None, rows):
    metadata, raw_path = row.split(b"\t", 1)
    path = raw_path.decode("utf-8")
    oid = metadata.split()[1].decode("ascii")
    size = int(subprocess.check_output(["git", "cat-file", "-s", oid]))
    if PurePosixPath(path).parts[0] in excluded or size > limit:
        raise SystemExit(f"Refusing generated/large Git object: {path} ({size:,} bytes)")
    count += 1
    total += size
    largest = max(largest, size)
if not count:
    raise SystemExit("No staged/tracked source files to validate")
print(f"PASS: {count} Git files, {total:,} bytes total; largest file {largest:,} bytes; no generated dependency directories.")
