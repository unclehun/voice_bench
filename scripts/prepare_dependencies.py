#!/usr/bin/env python3
"""Fetch fixed iOS libraries and XcodeGen. No Xcode installation or account required."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = json.loads((ROOT / "config/dependencies.json").read_text())


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare(name, offline=False):
    spec = LOCK[name]
    cache = ROOT / ".downloads"
    cache.mkdir(exist_ok=True)
    archive = cache / (name + "-" + spec["version"] + ".zip")
    if not archive.exists() or sha256(archive) != spec["sha256"]:
        if offline:
            raise RuntimeError(f"Missing or invalid archive: {archive}")
        partial = archive.with_suffix(".partial")
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--max-time", "300", spec["url"], "--output", str(partial)], check=True)
        if sha256(partial) != spec["sha256"]:
            raise RuntimeError(f"Checksum mismatch: {name}")
        partial.replace(archive)
    parent = ROOT / (".tools" if name == "xcodegen" else "Vendor")
    parent.mkdir(exist_ok=True)
    destination = parent / spec["directory"]
    marker = parent / (name + ".sha256")
    if destination.exists() and marker.exists() and marker.read_text().strip() == spec["sha256"]:
        return destination
    with tempfile.TemporaryDirectory(dir=parent) as temp:
        stage = Path(temp)
        with zipfile.ZipFile(archive) as bundle:
            for info in bundle.infolist():
                path = (stage / info.filename).resolve()
                if not path.is_relative_to(stage.resolve()):
                    raise RuntimeError("Unsafe archive path")
            bundle.extractall(stage)
        candidates = list(stage.rglob(spec["directory"]))
        if name == "xcodegen":
            candidates = [p for p in candidates if p.is_dir() and (p / "bin/xcodegen").is_file()]
        if len(candidates) != 1:
            raise RuntimeError(f"Unexpected archive layout for {name}: {candidates}")
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(str(candidates[0]), destination)
    if name == "xcodegen":
        (destination / "bin/xcodegen").chmod(0o755)
    marker.write_text(spec["sha256"] + "\n")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--only", choices=LOCK.keys())
    args = parser.parse_args()
    for name in ([args.only] if args.only else LOCK):
        print(f"Ready: {prepare(name, args.offline)}")
