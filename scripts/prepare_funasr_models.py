#!/usr/bin/env python3
"""Download and verify the pinned, phone-importable Fun-ASR-MLT-Nano INT8 set."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REVISION = "932d7dbb98623bd31314015b3bc0dac0dcf80acc"
REPOSITORY = "luigi000/fun-asr-mlt-nano-onnx-int8"
BASE = f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/"
VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
MERGES_GIT_BLOB = "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7"


def onnx_metadata(path):
    """Read only protobuf metadata; skip large graph/weight fields without loading them."""
    def integer(stream):
        value = shift = 0
        for _ in range(10):
            byte = stream.read(1)
            if not byte:
                raise RuntimeError(f"Truncated ONNX protobuf: {path}")
            number = byte[0]
            value |= (number & 127) << shift
            if number < 128:
                return value
            shift += 7
        raise RuntimeError("Invalid ONNX protobuf varint")

    import io
    values = {}
    with path.open("rb") as stream:
        while stream.tell() < path.stat().st_size:
            key = integer(stream)
            field, kind = key >> 3, key & 7
            if kind == 0:
                integer(stream)
            elif kind in (1, 5):
                stream.seek(8 if kind == 1 else 4, 1)
            elif kind == 2:
                size = integer(stream)
                if field != 14:
                    stream.seek(size, 1)
                    continue
                if size > 1024 * 1024:
                    raise RuntimeError("Unexpected ONNX metadata size")
                entry = io.BytesIO(stream.read(size))
                pair = {}
                while entry.tell() < size:
                    subkey = integer(entry)
                    if subkey & 7 != 2:
                        raise RuntimeError("Invalid ONNX metadata entry")
                    pair[subkey >> 3] = entry.read(integer(entry)).decode("utf-8")
                values[pair[1]] = pair[2]
            else:
                raise RuntimeError("Unsupported ONNX protobuf field")
    return values


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
    expected = json.loads((ROOT / "config/funasr-mlt-model-manifest.json").read_text())
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
    # Do not assume the original Qwen3 context length applies to this ONNX export.
    llm = onnx_metadata(output / "llm.int8.onnx")
    encoder = onnx_metadata(output / "encoder_adaptor.int8.onnx")
    contract = {"max_total_len": "512", "hidden_size": "1024", "num_layers": "28", "io_dtype": "float32"}
    if any(llm.get(name) != value for name, value in contract.items()):
        raise RuntimeError("FunASR LLM metadata differs from the app's validated 512-token contract")
    if encoder.get("lfr_window_size") != "7" or encoder.get("lfr_window_shift") != "6":
        raise RuntimeError("FunASR encoder LFR differs from the app's input contract")
    print("Verified native metadata: 512-token KV cache, 80-mel / LFR 7:6", flush=True)
    if not verify_only:
        shutil.copyfile(ROOT / "licenses/funasr-mlt-LICENSE", output / "LICENSE")
        shutil.copyfile(ROOT / "licenses/funasr-mlt-NOTICE", output / "NOTICE")
        vad_license = ROOT / "Models/VoiceBenchModels/VAD_LICENSE"
        if vad_license.is_file():
            shutil.copyfile(vad_license, output / "VAD_LICENSE")
        else:
            fetch("https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE", output / "VAD_LICENSE")
        (output / "manifest.json").write_text(json.dumps(expected, indent=2) + "\n")
        (output / "EXPORT_METADATA.json").write_text(json.dumps({"llm": llm, "encoder": encoder}, indent=2) + "\n")
        (output / "SOURCE.txt").write_text(
            f"Fun-ASR-MLT-Nano INT8 ONNX\nRepository: {REPOSITORY}\nRevision: {REVISION}\n{BASE}\n"
            f"VAD: {VAD_URL}\nKeep tokenizer/ and all its files. This model directly transcribes audio.\n")
    size = sum((output / name).stat().st_size for name in expected)
    print(f"Ready: {output}\nRequired assets: {size:,} bytes. Copy the whole folder to iPhone Documents/FunASR_MLT_Nano_INT8.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "Models/FunASR_MLT_Nano_INT8")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    prepare(args.output.resolve(), args.verify_only)
