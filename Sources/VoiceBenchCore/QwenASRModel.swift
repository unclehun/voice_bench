import Foundation

/// An independent ASR model; it does not consume Whisper language-ID decisions.
public enum QwenASRModel {
    public static let version = "qwen3-asr-0.6b-int8-2026-03-25-68818b2"
    public static let defaultDirectoryName = "Qwen3ASR_0_6B_INT8"
    public static let requiredFiles = [
        "conv_frontend.onnx", "encoder.int8.onnx", "decoder.int8.onnx",
        "tokenizer/vocab.json", "tokenizer/merges.txt", "tokenizer/tokenizer_config.json",
        "silero_vad.onnx"
    ]
}
