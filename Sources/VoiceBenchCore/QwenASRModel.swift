import Foundation

/// The deployed W4A32/block32 profile. Its persisted identity stays unchanged.
public enum QwenASRModel {
    public static let version = "qwen3-asr-0.6b-w4a32-block32-2026-10-30-v1"
    public static let defaultDirectoryName = "Qwen3ASR_0_6B_WeightOnly4"
    public static let requiredFiles = [
        "conv_frontend.onnx", "encoder.int8.onnx", "decoder.weight4.onnx",
        "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
        "silero_vad.onnx"
    ]
}
