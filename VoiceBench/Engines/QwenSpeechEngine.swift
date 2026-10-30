import AVFoundation
import OSLog
import SherpaOnnxC
import VoiceBenchCore

struct QwenSpeechFailure: LocalizedError, Sendable {
    let stage: String
    let summary: String
    let configuration: [String: String]
    var errorDescription: String? { "Qwen3-ASR 在 \(stage) 阶段失败：\(summary)" }
}

private final class QwenCStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

/// An independent multilingual recognizer. No language hint, translation or external LID routing.
actor QwenSpeechEngine {
    private let logger = Logger(subsystem: "com.voicebench.demo", category: "QwenASR")

    func transcribe(source: URL, models: URL, runID: UUID, cancellation: CancellationFlag,
                    temporaryFiles: AppTemporaryFiles = .live,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_models"
        var converted: URL?
        var metadata = ["qwen_model": QwenASRModel.version, "qwen_language_strategy": "model_native_auto",
            "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2", "provider": "cpu", "threads": "2",
            "sample_rate": "16000", "qwen_feature_dim": "128", "qwen_max_total_len": "1024",
            "qwen_max_new_tokens": "512", "qwen_temperature": "0", "qwen_top_p": "1", "qwen_seed": "0",
            "vad_max_seconds": "20", "vad_min_silence": "0.6", "vad_min_speech": "0",
            "edge_padding_ms": "200", "overlap": "clamped_to_previous_end", "offline": "true",
            "qwen_timestamps": "vad_region_only", "qwen_language_labels": "not_exposed_by_native_result",
            "qwen_output_guard_tokens": "496"]
        metadata["qwen_decoder_precision"] = "weight_only_int4_block32_float32_activations"
        metadata["qwen_embedding_precision"] = "original_bfloat16_storage_float32_compute"
        metadata["sherpa_git_sha"] = String(cString: SherpaOnnxGetGitSha1())
        metadata["audio_region_reader"] = AudioFiles.regionReaderVersion
        func checkCancellation() throws { try cancellation.check(); try Task.checkCancellation() }
        func event(_ name: String, detail: String = "") {
            logger.notice("VoiceBenchQwenASR run=\(runID.uuidString, privacy: .public) stage=\(name, privacy: .public) \(detail, privacy: .public)")
        }
        defer { if let converted { try? temporaryFiles.remove(converted) } }
        do {
            try checkCancellation()
            for name in QwenASRModel.requiredFiles {
                guard FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path) else {
                    throw BenchError("模型文件缺失：\(name)，请重新载入 \(QwenASRModel.defaultDirectoryName)。")
                }
            }
            stage = "initialize_qwen"; event(stage)
            let strings = QwenCStringArena()
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16000
            config.feat_config.feature_dim = 128
            config.model_config.qwen3_asr.conv_frontend = strings.add(models.appendingPathComponent("conv_frontend.onnx").path)
            config.model_config.qwen3_asr.encoder = strings.add(models.appendingPathComponent("encoder.int8.onnx").path)
            config.model_config.qwen3_asr.decoder = strings.add(models.appendingPathComponent("decoder.weight4.onnx").path)
            config.model_config.qwen3_asr.tokenizer = strings.add(models.appendingPathComponent("tokenizer", isDirectory: true).path)
            config.model_config.qwen3_asr.max_total_len = 1024
            config.model_config.qwen3_asr.max_new_tokens = 512
            config.model_config.qwen3_asr.temperature = 0
            config.model_config.qwen3_asr.top_p = 1
            config.model_config.qwen3_asr.seed = 0
            config.model_config.num_threads = 2
            config.model_config.provider = strings.add("cpu")
            config.decoding_method = strings.add("greedy_search")
            guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
                throw BenchError("Qwen3-ASR 初始化失败，请检查配套模型和可用内存。")
            }
            defer { SherpaOnnxDestroyOfflineRecognizer(recognizer); withExtendedLifetime(strings) {} }
            try checkCancellation()
            stage = "initialize_vad"; event(stage)
            var vadConfig = SherpaOnnxVadModelConfig()
            vadConfig.silero_vad.model = strings.add(models.appendingPathComponent("silero_vad.onnx").path)
            vadConfig.silero_vad.threshold = 0.5
            vadConfig.silero_vad.min_silence_duration = 0.6
            vadConfig.silero_vad.min_speech_duration = 0
            vadConfig.silero_vad.window_size = 512
            // Keep the audio + generated text within the exported decoder's bounded KV cache.
            vadConfig.silero_vad.max_speech_duration = 20
            vadConfig.sample_rate = 16000; vadConfig.num_threads = 1
            vadConfig.provider = strings.add("cpu")
            guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 32) else { throw BenchError("Qwen 的 Silero VAD 初始化失败。") }
            defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
            let ready = ProcessInfo.processInfo.systemUptime
            stage = "convert_audio"; event(stage)
            let fileURL = try temporaryFiles.file(extension: "caf", prefix: "Qwen-")
            converted = fileURL
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            try AudioFiles.convert(source: source, target: fileURL, format: format, cancellation: cancellation)
            let input = try AVAudioFile(forReading: fileURL)
            let slices = try AVAudioFile(forReading: fileURL)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 512)!
            var segments: [Segment] = []
            var previousEnd: Int64 = 0
            func drain() async throws {
                while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                    try checkCancellation()
                    guard let speech = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw BenchError("无法读取 Qwen VAD 片段。") }
                    let rawStart = Int64(speech.pointee.start)
                    let rawEnd = rawStart + Int64(speech.pointee.n)
                    SherpaOnnxDestroySpeechSegment(speech)
                    SherpaOnnxVoiceActivityDetectorPop(vad)
                    let lo = max(previousEnd, max(0, rawStart - 3200))
                    let hi = min(input.length, rawEnd + 3200)
                    guard hi > lo else { continue }
                    let samples = try AudioFiles.samples(file: slices, start: lo, end: hi)
                    guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw BenchError("无法创建 Qwen 识别流。") }
                    defer { SherpaOnnxDestroyOfflineStream(stream) }
                    stage = "decode_segment"
                    event(stage, detail: "index=\(segments.count) start=\(Double(lo) / 16000) end=\(Double(hi) / 16000)")
                    let segmentStart = ProcessInfo.processInfo.systemUptime
                    samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
                    SherpaOnnxDecodeOfflineStream(recognizer, stream)
                    try checkCancellation()
                    guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw BenchError("Qwen 未返回识别结果。") }
                    let text = result.pointee.text.map { String(cString: $0) } ?? ""
                    let tokens = result.pointee.count
                    SherpaOnnxDestroyOfflineRecognizerResult(result)
                    metadata["qwen_last_token_count"] = String(tokens)
                    // Native results strip a leading language scaffold (up to 16 tokens).
                    // Leave that margin when checking whether generation may have hit 512.
                    guard tokens < 496 else { throw BenchError("Qwen 片段接近输出上限，结果可能不完整，请缩短录音后重试。") }
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw BenchError("Qwen 检测到语音片段但未返回文字，请查看运行日志后重试。")
                    }
                    let item = Segment(id: segments.count, startSeconds: Double(lo) / 16000, endSeconds: Double(hi) / 16000,
                        text: text, elapsedMS: (ProcessInfo.processInfo.systemUptime - segmentStart) * 1000)
                    segments.append(item); previousEnd = hi
                    metadata["qwen_completed_segments"] = String(segments.count)
                    await progress(item)
                }
            }
            stage = "scan_vad"; event(stage)
            while input.framePosition < input.length {
                try checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(512, input.length - input.framePosition)))
                guard let pointer = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw BenchError("Qwen 派生音频提前结束。") }
                var window = Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
                window += Array(repeating: 0, count: 512 - window.count)
                window.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
                try await drain()
                stage = "scan_vad"
            }
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            try await drain()
            try checkCancellation()
            stage = "cleanup_audio"
            try temporaryFiles.remove(fileURL); converted = nil
            metadata["qwen_temporary_audio_removed"] = "true"
            metadata["qwen_completed_segments"] = String(segments.count)
            event("completed", detail: "segments=\(segments.count)")
            return EngineOutput(preparationMS: (ready - start) * 1000,
                transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000, segments: segments, configuration: metadata)
        } catch {
            let nsError = error as NSError
            metadata["qwen_error_stage"] = stage
            metadata["qwen_error_domain"] = nsError.domain
            metadata["qwen_error_code"] = String(nsError.code)
            metadata["qwen_elapsed_ms"] = String((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if let fileURL = converted {
                do { try temporaryFiles.remove(fileURL); converted = nil; metadata["qwen_temporary_audio_removed"] = "true" }
                catch { metadata["qwen_temporary_audio_removed"] = "false"; metadata["qwen_cleanup_error"] = error.localizedDescription }
            }
            event("failed", detail: "stage=\(stage) domain=\(nsError.domain) code=\(nsError.code)")
            throw QwenSpeechFailure(stage: stage, summary: error.localizedDescription, configuration: metadata)
        }
    }
}
