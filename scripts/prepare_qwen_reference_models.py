#!/usr/bin/env python3
"""Prepare the pinned official Qwen checkpoint for offline reference experiments."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "config/qwen-reference-model-manifest.json"


def verify(path, asset):
    if not path.is_file() or path.stat().st_size != asset["size"]:
        return False
    sha = hashlib.sha256() if "sha256" in asset else hashlib.sha1()
    if "sha256" not in asset:
        sha.update(f"blob {asset['size']}\0".encode())
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest() == asset.get("sha256", asset["blobId"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "Models/Qwen3ASR_0_6B_OfficialReference")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    output = args.output.resolve()
    if not args.verify_only:
        output.mkdir(parents=True, exist_ok=True)
    for name, asset in manifest["files"].items():
        target = output / name
        if target.exists():
            if not verify(target, asset):
                raise RuntimeError(f"Refusing to replace mismatched existing asset: {target}")
            print(f"Verified existing {name}", flush=True)
            continue
        if args.verify_only:
            raise RuntimeError(f"Missing asset: {target}")
        partial = target.with_name(target.name + ".part")
        if not verify(partial, asset):
            url = f"https://huggingface.co/{manifest['repository']}/resolve/{manifest['revision']}/{name}"
            print(f"Downloading {name}: {asset['size']:,} bytes", flush=True)
            subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4",
                            "--connect-timeout", "30", "--max-time", "3600", "--continue-at", "-",
                            "--output", str(partial), url], check=True)
        if not verify(partial, asset):
            raise RuntimeError(f"Checksum mismatch: {partial}; asset not installed")
        partial.replace(target)
        print(f"Verified {name}", flush=True)
    if not args.verify_only:
        shutil.copyfile(MANIFEST, output / "SOURCE.json")
        shutil.copyfile(ROOT / "licenses/qwen3-asr-LICENSE", output / "LICENSE")
    print(f"Ready: {output}; offline official reference only", flush=True)


if __name__ == "__main__":
    main()
