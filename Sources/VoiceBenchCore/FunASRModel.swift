import Foundation

/// The MLT checkpoint is separate from the three-language Fun-ASR-Nano.
public enum FunASRModel {
    public static let version = "fun-asr-mlt-nano-2512-int8-932d7db"
    public static let defaultDirectoryName = "FunASR_MLT_Nano_INT8"
    public static let requiredFiles = [
        "encoder_adaptor.int8.onnx", "embedding.int8.onnx", "llm.int8.onnx",
        "tokenizer/tokenizer.json", "tokenizer/vocab.json", "tokenizer/merges.txt",
        "tokenizer/tokenizer_config.json", "tokenizer/config.json", "tokenizer/generation_config.json",
        "silero_vad.onnx"
    ]
    // This pinned export has a 512-token KV cache, including audio + prompt + output.
    // Prefer a complete natural phrase. Budget checks subdivide only when necessary.
    public static let maximumSpeechSeconds: Float = 20
    public static let maximumNewTokens: Int32 = 512
}
