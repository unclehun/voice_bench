#!/usr/bin/env python3
"""Download and verify the pinned, phone-importable Qwen3-ASR 0.6B INT8 set."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "68818b2313fe77bd06f6a7c5068ff3ef59d02b8a"
REPOSITORY = "csukuangfj2/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25"
BASE = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/"
VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
MERGES_GIT_BLOB = "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def fetch(url, target):
    subprocess.run([
        "curl", "--fail", "--location", "--silent", "--show-error", "--retry", "4",
        "--connect-timeout", "30", "--max-time", "1800", "--continue-at", "-",
        "--output", str(target), url,
    ], check=True)


def prepare(output, verify_only=False):
    expected = json.loads((ROOT / "config/qwen-model-manifest.json").read_text())
    if not verify_only:
        output.mkdir(parents=True, exist_ok=True)

    def asset(item):
        name, checksum = item
        target = output / name
        if target.is_file():
            if digest(target) != checksum:
                raise RuntimeError(f"Refusing to replace an existing mismatched file: {target}")
            print(f"Verified existing {name}", flush=True)
            return
        if verify_only:
            raise RuntimeError(f"Missing model asset: {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if name == "silero_vad.onnx":
            for folder in ["VoiceBenchModels", "WhisperTiny_INT8"]:
                existing = ROOT / "Models" / folder / name
                if existing.is_file() and digest(existing) == checksum:
                    shutil.copyfile(existing, target)
                    print(f"Copied verified {name}", flush=True)
                    return
        partial = target.with_name(target.name + ".part")
        if not partial.is_file() or digest(partial) != checksum:
            print(f"Downloading {name}", flush=True)
            fetch(VAD_URL if name == "silero_vad.onnx" else BASE + name, partial)
        if digest(partial) != checksum:
            raise RuntimeError(f"SHA-256 mismatch: {partial}; model was not installed")
        if name == "tokenizer/merges.txt":
            # This file is a regular Git blob upstream, rather than an LFS object.
            content = partial.read_bytes()
            git_blob = hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()
            if git_blob != MERGES_GIT_BLOB:
                raise RuntimeError("Tokenizer differs from the pinned upstream Git blob")
        partial.replace(target)
        print(f"Verified {name}: {target.stat().st_size:,} bytes", flush=True)

    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(asset, expected.items()))
    if not verify_only:
        shutil.copyfile(ROOT / "licenses/qwen3-asr-LICENSE", output / "LICENSE")
        shutil.copyfile(ROOT / "licenses/qwen3-asr-NOTICE", output / "NOTICE")
        vad_license = ROOT / "Models/VoiceBenchModels/VAD_LICENSE"
        if vad_license.is_file():
            shutil.copyfile(vad_license, output / "VAD_LICENSE")
        else:
            fetch("https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE", output / "VAD_LICENSE")
        (output / "manifest.json").write_text(json.dumps(expected, indent=2) + "\n")
        (output / "SOURCE.txt").write_text(
            f"Qwen3-ASR 0.6B INT8 ONNX\nRepository: {REPOSITORY}\nRevision: {REVISION}\n{BASE}\n"
            f"VAD: {VAD_URL}\nKeep tokenizer/ and its three files. This model directly transcribes audio.\n")
    size = sum((output / name).stat().st_size for name in expected)
    print(f"Ready: {output}\nRequired assets: {size:,} bytes. Copy the whole folder to iPhone Documents/Qwen3ASR_0_6B_INT8.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "Models/Qwen3ASR_0_6B_INT8")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    prepare(args.output.resolve(), args.verify_only)
