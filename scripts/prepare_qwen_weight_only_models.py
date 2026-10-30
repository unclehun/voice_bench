#!/usr/bin/env python3
"""Build the candidate Qwen decoder from pinned official weights and the existing graph."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
RECIPE = "w4a32-block32-original-bf16-embedding-v1"
FILES = ["conv_frontend.onnx", "encoder.int8.onnx", "decoder.weight4.onnx",
         "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json", "silero_vad.onnx"]


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build_decoder(template, checkpoint, destination):
    import numpy as np
    import onnx
    import torch
    import onnxruntime
    from safetensors import safe_open
    from onnxruntime.quantization.matmul_nbits_quantizer import DefaultWeightOnlyQuantConfig, DefaultWeightOnlyQuantizer
    if onnxruntime.__version__ != "1.23.2" or onnx.__version__ != "1.17.0":
        raise RuntimeError("Use the pinned qwen-reference Python environment for reproducible model generation")
    model = onnx.load(str(template))
    producers = {out: node for node in model.graph.node for out in node.output}
    consumers = {}
    for node in model.graph.node:
        for name in node.input:
            consumers.setdefault(name, []).append(node)
    inits = {x.name: x for x in model.graph.initializer}
    quantizer = DefaultWeightOnlyQuantizer(DefaultWeightOnlyQuantConfig(
        block_size=32, bits=4, is_symmetric=True, accuracy_level=1, op_types_to_quantize=("MatMul",)))
    replacements, new_initializers = {}, []
    with safe_open(str(checkpoint), framework="pt", device="cpu") as weights:
        for node in model.graph.node:
            if node.op_type != "MatMulInteger":
                continue
            match = re.fullmatch(r"/(q_proj|k_proj|v_proj|o_proj|gate_proj|up_proj|down_proj)(?:_(\d+))?/MatMul_quant", node.name)
            if node.name == "/lm_head/MatMul_quant":
                key = "thinker.lm_head.weight"
            elif match:
                part, layer = match[1], int(match[2] or 0)
                section = "self_attn" if part in {"q_proj", "k_proj", "v_proj", "o_proj"} else "mlp"
                key = f"thinker.model.layers.{layer}.{section}.{part}.weight"
            else:
                raise RuntimeError(f"Unrecognized template layer: {node.name}")
            quantize_input = producers[node.input[0]]
            if quantize_input.op_type != "DynamicQuantizeLinear":
                raise RuntimeError("Unexpected activation quantization path")
            cast = next(x for x in consumers[node.output[0]] if x.op_type == "Cast")
            final = next(x for x in consumers[cast.output[0]] if x.op_type == "Mul")
            weight = np.ascontiguousarray(weights.get_tensor(key).float().numpy().T)
            if list(weight.shape) != list(inits[node.input[1]].dims):
                raise RuntimeError(f"Weight shape mismatch: {key}")
            packed, scales, _ = quantizer.qbits_block_quant(weight)
            b_name, s_name = key + ".W4", key + ".W4_scales"
            new_initializers += [onnx.numpy_helper.from_array(packed, b_name), onnx.numpy_helper.from_array(scales, s_name)]
            replacements[final.name] = onnx.helper.make_node(
                "MatMulNBits", [quantize_input.input[0], b_name, s_name], list(final.output),
                name=node.name + "_WeightOnly4", domain="com.microsoft",
                K=weight.shape[0], N=weight.shape[1], bits=4, block_size=32, accuracy_level=1)
        if len(replacements) != 197:
            raise RuntimeError("Template does not contain the expected 28 decoder layers and output head")
        base = "thinker.model.embed_tokens.weight"
        embedding = weights.get_tensor(base)
        if embedding.dtype != torch.bfloat16 or list(embedding.shape) != [151936, 1024]:
            raise RuntimeError("Unexpected original embedding")
        tensor = onnx.TensorProto()
        tensor.name = base + ".original_bf16"; tensor.data_type = onnx.TensorProto.BFLOAT16
        tensor.dims.extend(embedding.shape); tensor.raw_data = embedding.view(torch.uint16).numpy().tobytes()
        new_initializers.append(tensor)
        embedding_cast = onnx.helper.make_node("Cast", [tensor.name], [base + ".original_fp32"],
                                               to=onnx.TensorProto.FLOAT, name="OriginalEmbeddingToFloat32")
        gather = next(x for x in model.graph.node if x.op_type == "Gather" and x.input[0] == base + "_quantized")
        dequantize = next(x for x in consumers[gather.output[0]] if x.op_type == "DequantizeLinear")
        replacements[dequantize.name] = onnx.helper.make_node(
            "Gather", [embedding_cast.output[0], gather.input[1]], list(dequantize.output),
            name="OriginalEmbeddingLookup", axis=0)
    nodes = [embedding_cast] + [replacements.get(x.name, x) for x in model.graph.node]
    needed = {x.name for x in model.graph.output}
    kept = []
    for node in reversed(nodes):
        if any(x in needed for x in node.output):
            kept.append(node); needed.update(node.input)
    kept.reverse()
    del model.graph.node[:]; model.graph.node.extend(kept)
    originals = [x for x in model.graph.initializer if x.name in needed]
    del model.graph.initializer[:]; model.graph.initializer.extend(originals + [x for x in new_initializers if x.name in needed])
    valid_names = needed | {x for n in kept for x in n.output}
    infos = [x for x in model.graph.value_info if x.name in valid_names]
    del model.graph.value_info[:]; model.graph.value_info.extend(infos)
    if not any(x.domain == "com.microsoft" for x in model.opset_import):
        model.opset_import.extend([onnx.helper.make_operatorsetid("com.microsoft", 1)])
    props = {x.key: x.value for x in model.metadata_props}
    props["voicebench.decoder_recipe"] = RECIPE
    props["voicebench.reference_revision"] = "5eb144179a02acc5e5ba31e748d22b0cf3e303b0"
    onnx.helper.set_model_props(model, props)
    onnx.checker.check_model(model)
    onnx.save_model(model, str(destination))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, default=ROOT / "Models/Qwen3ASR_0_6B_WeightOnly4")
    p.add_argument("--verify-only", action="store_true")
    p.add_argument("--record-manifest", action="store_true", help="Maintainer-only first generation; refuses to replace a manifest")
    args = p.parse_args()
    manifest_path = ROOT / "config/qwen-weight-only-model-manifest.json"
    expected = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    if args.record_manifest and expected is not None:
        raise RuntimeError("Refusing to overwrite a recorded model manifest")
    out = args.output.resolve()
    if args.verify_only:
        if expected is None or any(not (out/n).is_file() or digest(out/n) != expected[n] for n in FILES):
            raise RuntimeError("Candidate model verification failed")
        print(f"Verified candidate: {out}"); return
    if out.exists() and any(out.iterdir()):
        if expected is not None and all((out/n).is_file() and digest(out/n) == expected[n] for n in FILES):
            print(f"Verified existing candidate: {out}"); return
        raise RuntimeError("Refusing to replace an existing model directory; use --verify-only")
    from prepare_qwen_reference_models import verify
    old = ROOT / "Models/Qwen3ASR_0_6B_INT8"
    original = ROOT / "Models/Qwen3ASR_0_6B_OfficialReference"
    legacy = json.loads((ROOT / "config/qwen-model-manifest.json").read_text())
    for name, checksum in legacy.items():
        if digest(old/name) != checksum:
            raise RuntimeError(f"Template asset hash mismatch: {name}")
    ref = json.loads((ROOT / "config/qwen-reference-model-manifest.json").read_text())
    if not verify(original/"model.safetensors", ref["files"]["model.safetensors"]):
        raise RuntimeError("Official checkpoint hash mismatch")
    out.mkdir(parents=True, exist_ok=True)
    partial = out / "decoder.weight4.onnx.part"
    build_decoder(old/"decoder.int8.onnx", original/"model.safetensors", partial)
    partial.replace(out/"decoder.weight4.onnx")
    for name in FILES:
        if name != "decoder.weight4.onnx":
            (out/name).parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(old/name, out/name)
    hashes = {name: digest(out/name) for name in FILES}
    if expected is not None and hashes != expected:
        raise RuntimeError("Generated bytes differ from the pinned candidate; do not import")
    if args.record_manifest:
        manifest_path.write_text(json.dumps(hashes, indent=2)+"\n")
    for name in ["LICENSE", "NOTICE", "VAD_LICENSE"]:
        shutil.copyfile(old/name, out/name)
    (out/"manifest.json").write_text(json.dumps(hashes, indent=2)+"\n")
    (out/"SOURCE.txt").write_text(f"Qwen3-ASR candidate {RECIPE}\nOfficial checkpoint {ref['repository']}@{ref['revision']}\nTemplate: existing pinned Qwen INT8 graph. Encoder/frontend/tokenizer/VAD unchanged.\nBuilt by scripts/prepare_qwen_weight_only_models.py; decoder activations remain Float32.\n")
    print(f"Ready: {out}; {sum((out/n).stat().st_size for n in FILES):,} bytes")


if __name__ == "__main__":
    main()
