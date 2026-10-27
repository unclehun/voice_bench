#!/usr/bin/env python3
"""Download pinned, phone-importable Whisper Tiny INT8 language-ID assets."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "65176e2deb88badc814a94058666cadccc29b61c"
BASE = f"https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/{REVISION}/"
VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def prepare(output):
    expected = json.loads((ROOT / "config/language-model-manifest.json").read_text())
    output.mkdir(parents=True, exist_ok=True)
    for name, checksum in expected.items():
        target = output / name
        if target.exists():
            if digest(target) != checksum:
                raise RuntimeError(f"Refusing to replace an existing mismatched file: {target}")
            print(f"Verified existing {name}", flush=True)
            continue
        existing_vad = ROOT / "Models/VoiceBenchModels/silero_vad.onnx"
        if name == "silero_vad.onnx" and existing_vad.is_file() and digest(existing_vad) == checksum:
            shutil.copyfile(existing_vad, target)
            print(f"Copied verified {name}", flush=True)
            continue
        url = VAD_URL if name == "silero_vad.onnx" else BASE + name
        partial = output / (name + ".part")
        print(f"Downloading {name}", flush=True)
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                        "--max-time", "900", "--continue-at", "-", "--output", str(partial), url], check=True)
        if digest(partial) != checksum:
            raise RuntimeError(f"SHA-256 mismatch: {partial}; model was not installed")
        partial.replace(target)
        print(f"Verified {name}: {target.stat().st_size:,} bytes", flush=True)
    shutil.copyfile(ROOT / "licenses/whisper-LICENSE", output / "LICENSE")
    vad_license = ROOT / "Models/VoiceBenchModels/VAD_LICENSE"
    if vad_license.is_file():
        shutil.copyfile(vad_license, output / "VAD_LICENSE")
    else:
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
                        "--output", str(output / "VAD_LICENSE"),
                        "https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE"], check=True)
    (output / "manifest.json").write_text(json.dumps(expected, indent=2) + "\n")
    (output / "SOURCE.txt").write_text(
        f"Whisper Tiny multilingual ONNX INT8, revision {REVISION}\n{BASE}\n{VAD_URL}\n"
        "Used for spoken-language identification, not the Apple transcription itself.\n")
    size = sum((output / name).stat().st_size for name in expected)
    print(f"Ready: {output}\nRequired assets: {size:,} bytes. Copy the whole folder to iPhone Documents/WhisperTiny_INT8.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "Models/WhisperTiny_INT8")
    prepare(parser.parse_args().output.resolve())
