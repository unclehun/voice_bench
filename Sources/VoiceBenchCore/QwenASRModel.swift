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

/// An independent comparison profile; the original INT8 model and its history stay valid.
public enum QwenWeightOnlyModel {
    public static let version = "qwen3-asr-0.6b-w4a32-block32-2026-10-30-v1"
    public static let defaultDirectoryName = "Qwen3ASR_0_6B_WeightOnly4"
    public static let requiredFiles = QwenASRModel.requiredFiles.map {
        $0 == "decoder.int8.onnx" ? "decoder.weight4.onnx" : $0
    }
}

public enum QwenASRVariant: Equatable, Sendable {
    case original, weightOnly4
    public var version: String { self == .original ? QwenASRModel.version : QwenWeightOnlyModel.version }
    public var requiredFiles: [String] { self == .original ? QwenASRModel.requiredFiles : QwenWeightOnlyModel.requiredFiles }
    public var decoderFile: String { self == .original ? "decoder.int8.onnx" : "decoder.weight4.onnx" }
    public var directoryName: String { self == .original ? QwenASRModel.defaultDirectoryName : QwenWeightOnlyModel.defaultDirectoryName }
}
