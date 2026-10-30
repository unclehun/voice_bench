#!/usr/bin/env python3
"""Run the official offline Qwen implementation on frozen PCM without reference text."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import time


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--pcm", type=Path, required=True, help="16kHz mono little-endian Float32")
    parser.add_argument("--regions", type=Path, required=True, help="Frozen native VAD regions JSON")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--matrix", choices=["core", "short-pauses", "exact"], default="core")
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()
    if args.output.exists():
        raise RuntimeError("Refusing to overwrite an existing experiment report")
    import numpy as np
    import torch
    import qwen_asr
    from qwen_asr import Qwen3ASRModel

    torch.set_num_threads(args.threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    audio = np.fromfile(args.pcm, dtype="<f4")
    if not len(audio) or not np.isfinite(audio).all():
        raise ValueError("Empty or invalid PCM")
    regions = json.loads(args.regions.read_text())
    cases = [{"id": "exact-auto", "start": 19.710, "end": 36.976, "language": None}]
    if args.matrix == "core":
        cases.append({"id": "exact-Chinese", "start": 19.710, "end": 36.976, "language": "Chinese"})
        cases.append({"id": "whole-auto", "start": 0, "end": len(audio)/16000, "language": None})
        cases += [{"id": f"original-region-{i}", "start": a, "end": b, "language": None}
                  for i, (a, b) in enumerate(regions["silence_0.6_max_20"])]
    elif args.matrix == "short-pauses":
        cases += [{"id": f"short-region-{i}", "start": a, "end": b, "language": None}
                  for i, (a, b) in enumerate(regions["silence_0.2_max_20"])]
    package_root = Path(qwen_asr.__file__).parent
    versions = {name: importlib.metadata.version(name) for name in
                ["torch", "transformers", "qwen-asr", "numpy", "accelerate", "librosa"]}
    report = dict(status="initializing", platform=platform.platform(), versions=versions,
                  official_source_sha256={str(p.relative_to(package_root)): digest(p)
                                          for p in sorted(package_root.rglob("*.py"))},
                  source=json.loads((args.models/"SOURCE.json").read_text()),
                  pcm_sha256=digest(args.pcm), sample_rate=16000, pcm_samples=len(audio),
                  regions_sha256=digest(args.regions), device="cpu", dtype="float32",
                  attention="eager", threads=args.threads, seed=0, context="",
                  do_sample=False, num_beams=1, max_new_tokens=512, matrix=args.matrix, results=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        partial = args.output.with_suffix(args.output.suffix+".tmp")
        partial.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
        partial.replace(args.output)

    save()
    print("Loading pinned official checkpoint on CPU / Float32", flush=True)
    started = time.monotonic()
    asr = Qwen3ASRModel.from_pretrained(
        str(args.models.resolve()), dtype=torch.float32, device_map="cpu",
        attn_implementation="eager", max_inference_batch_size=1,
        max_new_tokens=512, local_files_only=True)
    asr.model.eval()
    asr.model.generation_config.do_sample = False
    asr.model.generation_config.num_beams = 1
    report["load_seconds"] = time.monotonic()-started
    report["generation_config"] = asr.model.generation_config.to_dict()
    original_generate = asr.model.generate
    captured = []

    def capture_generate(*positional, **kwargs):
        output = original_generate(*positional, **kwargs)
        ids = output if isinstance(output, torch.Tensor) else output.sequences
        inputs = kwargs.get("input_ids")
        input_length = int(inputs.shape[-1]) if inputs is not None else 0
        for i, seq in enumerate(ids):
            generated = seq[input_length:].tolist()
            eos = asr.model.generation_config.eos_token_id
            eos_ids = eos if isinstance(eos, list) else [eos]
            captured.append(dict(input_token_ids=inputs[i].tolist() if inputs is not None else None,
                                 generated_token_ids=generated, generated_count=len(generated),
                                 raw_decoded=asr.processor.tokenizer.decode(generated, skip_special_tokens=False),
                                 stop_evidence="eos_observed" if generated and generated[-1] in eos_ids else
                                 "limit_reached" if len(generated) >= 512 else "not_exposed"))
        return output

    asr.model.generate = capture_generate
    report["status"] = "running"
    save()
    for case in cases:
        lo, hi = round(case["start"]*16000), round(case["end"]*16000)
        if not 0 <= lo < hi <= len(audio):
            raise ValueError(f"Invalid case bounds: {case}")
        samples = np.array(audio[lo:hi], dtype=np.float32, copy=True)
        captured.clear()
        print(f"Decoding {case['id']}: {lo}–{hi} samples", flush=True)
        started = time.monotonic()
        with torch.inference_mode():
            result = asr.transcribe(audio=(samples, 16000), language=case["language"],
                                    context="", return_time_stamps=False)
        if len(result) != 1:
            raise RuntimeError("Expected one result")
        row = dict(case, start_frame=lo, end_frame=hi, samples_sha256=hashlib.sha256(samples.tobytes()).hexdigest(),
                   text=result[0].text, returned_language=result[0].language,
                   elapsed_seconds=time.monotonic()-started, generation=list(captured))
        report["results"].append(row)
        save()
        print(json.dumps({k:v for k,v in row.items() if k!="generation"}, ensure_ascii=False), flush=True)
    report["status"] = "completed"
    save()


if __name__ == "__main__":
    main()
