import Foundation

/// Full multilingual transcription, independent of the retired Whisper Tiny language router.
public enum WhisperTurboModel {
    public static let version = "whisper-large-v3-turbo-int8-2ca6ff6"
    public static let defaultDirectoryName = "WhisperLargeV3Turbo_INT8"
    public static let requiredFiles = [
        "turbo-encoder.int8.onnx", "turbo-decoder.int8.onnx", "turbo-tokens.txt", "silero_vad.onnx"
    ]

    /// sherpa-onnx 1.13.8 caps Whisper generation at ~6 tokens/audio second and text_ctx/2.
    /// Allow one token of tolerance for feature-frame rounding when detecting a capped result.
    public static func outputGuardTokenCount(sampleCount: Int) -> Int {
        max(1, min(224, Int(Double(max(0, sampleCount)) / 16000 * 6)) - 1)
    }
}
