#!/usr/bin/env python3
"""Prepare a phone-importable model folder, including a SHA-256 transfer manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MODEL = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
BASE = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"


def fetch(url, path):
    subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--max-time", "900", url, "--output", str(path)], check=True)


def prepare(output):
    if output.exists():
        raise RuntimeError(f"Output already exists; choose another --output to avoid replacing it: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        stage = Path(temp)
        archive = stage / "model.tar.bz2"
        fetch(BASE + MODEL + ".tar.bz2", archive)
        folder = stage / "VoiceBenchModels"
        folder.mkdir()
        with tarfile.open(archive) as bundle:
            wanted = {"model.int8.onnx", "tokens.txt", "LICENSE"}
            for member in bundle.getmembers():
                name = Path(member.name).name
                if name not in wanted or not member.isfile():
                    continue
                if (folder / name).exists():
                    raise RuntimeError(f"Ambiguous archive entry: {name}")
                with bundle.extractfile(member) as source, (folder / name).open("wb") as target:
                    shutil.copyfileobj(source, target)
        fetch(BASE + "silero_vad.onnx", folder / "silero_vad.onnx")
        fetch("https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE", folder / "VAD_LICENSE")
        hashes = {}
        for name in ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"]:
            path = folder / name
            if not path.is_file() or path.stat().st_size == 0:
                raise RuntimeError(f"Missing model file: {name}")
            digest = hashlib.sha256()
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
            hashes[name] = digest.hexdigest()
        expected = json.loads((ROOT / "config/model-manifest.json").read_text())
        if hashes != expected:
            raise RuntimeError("Model contents differ from the pinned, verified model manifest. Do not silently update hashes.")
        (folder / "manifest.json").write_text(json.dumps(hashes, indent=2) + "\n")
        (folder / "SOURCE.txt").write_text(BASE + MODEL + ".tar.bz2\n" + BASE + "silero_vad.onnx\n")
        shutil.move(folder, output)
    print(f"Ready: {output}\nTransfer this folder to iPhone Files and select it in the app.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "Models/VoiceBenchModels")
    args = parser.parse_args()
    prepare(args.output.resolve())
