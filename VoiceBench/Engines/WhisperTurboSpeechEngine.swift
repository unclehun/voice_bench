import AVFoundation
import OSLog
import SherpaOnnxC
import VoiceBenchCore

struct WhisperTurboSpeechFailure: LocalizedError, Sendable {
    let stage: String
    let summary: String
    let configuration: [String: String]
    var errorDescription: String? { "Whisper large-v3-turbo 在 \(stage) 阶段失败：\(summary)" }
}

private final class WhisperTurboCStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

/// Same PCM/VAD/CPU pipeline as Qwen; Whisper selects its language internally and transcribes.
actor WhisperTurboSpeechEngine {
    private let logger = Logger(subsystem: "com.voicebench.demo", category: "WhisperTurbo")

    func transcribe(source: URL, models: URL, runID: UUID, cancellation: CancellationFlag,
                    temporaryFiles: AppTemporaryFiles = .live,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_models"
        var converted: URL?
        var tokenTable: URL?
        var metadata = ["audio_region_reader": AudioFiles.regionReaderVersion, "whisper_turbo_model": WhisperTurboModel.version,
            "whisper_turbo_language_strategy": "model_native_auto", "whisper_turbo_task": "transcribe",
            "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2", "provider": "cpu", "threads": "2",
            "sample_rate": "16000", "whisper_turbo_feature_dim": "128", "whisper_turbo_tail_paddings": "300",
            "vad_max_seconds": "20", "vad_min_silence": "0.6", "vad_min_speech": "0",
            "edge_padding_ms": "200", "overlap": "clamped_to_previous_end", "offline": "true",
            "whisper_turbo_timestamps": "vad_region_only", "whisper_turbo_external_language_detection": "false",
            "whisper_turbo_decoding": "greedy_search", "whisper_turbo_output_guard": "native_duration_cap_minus_1",
            "whisper_turbo_budget_retry_count": "0", "whisper_turbo_retry_policy": "capped_result_then_silence_to_29s",
            "whisper_turbo_text_decoder": WhisperByteTokens.version]
        func checkCancellation() throws { try cancellation.check(); try Task.checkCancellation() }
        func event(_ name: String, detail: String = "") {
            logger.notice("VoiceBenchWhisperTurbo run=\(runID.uuidString, privacy: .public) stage=\(name, privacy: .public) \(detail, privacy: .public)")
        }
        defer { if let converted { try? temporaryFiles.remove(converted) } }
        defer { if let tokenTable { try? temporaryFiles.remove(tokenTable) } }
        do {
            try checkCancellation()
            for name in WhisperTurboModel.requiredFiles {
                guard FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path) else {
                    throw BenchError("模型文件缺失：\(name)，请重新载入 WhisperLargeV3Turbo_INT8。")
                }
            }
            stage = "prepare_token_table"; event(stage)
            let tableURL = try temporaryFiles.file(extension: "txt", prefix: "WhisperTokens-")
            tokenTable = tableURL
            let originalTable = try Data(contentsOf: models.appendingPathComponent("turbo-tokens.txt"))
            try WhisperByteTokens.transportTable(from: originalTable).write(to: tableURL, options: .atomic)
            try checkCancellation()
            stage = "initialize_whisper_turbo"; event(stage)
            let strings = WhisperTurboCStringArena()
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16000
            config.feat_config.feature_dim = 128
            config.model_config.whisper.encoder = strings.add(models.appendingPathComponent("turbo-encoder.int8.onnx").path)
            config.model_config.whisper.decoder = strings.add(models.appendingPathComponent("turbo-decoder.int8.onnx").path)
            config.model_config.tokens = strings.add(tableURL.path)
            config.model_config.whisper.language = strings.add("")
            config.model_config.whisper.task = strings.add("transcribe")
            config.model_config.whisper.tail_paddings = 300
            config.model_config.whisper.enable_token_timestamps = 0
            config.model_config.whisper.enable_segment_timestamps = 0
            config.model_config.num_threads = 2
            config.model_config.provider = strings.add("cpu")
            config.decoding_method = strings.add("greedy_search")
            guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
                throw BenchError("Whisper large-v3-turbo 初始化失败，请检查配套模型和可用内存。")
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
            // Match Qwen's VAD settings and stay below Whisper's 30-second acoustic window.
            vadConfig.silero_vad.max_speech_duration = 20
            vadConfig.sample_rate = 16000; vadConfig.num_threads = 1
            vadConfig.provider = strings.add("cpu")
            guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 32) else { throw BenchError("Whisper 的 Silero VAD 初始化失败。") }
            defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
            let ready = ProcessInfo.processInfo.systemUptime
            stage = "convert_audio"; event(stage)
            let fileURL = try temporaryFiles.file(extension: "caf", prefix: "Whisper-")
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
                    guard let speech = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw BenchError("无法读取 Whisper VAD 片段。") }
                    let rawStart = Int64(speech.pointee.start)
                    let rawEnd = rawStart + Int64(speech.pointee.n)
                    SherpaOnnxDestroySpeechSegment(speech)
                    SherpaOnnxVoiceActivityDetectorPop(vad)
                    let lo = max(previousEnd, max(0, rawStart - 3200))
                    let hi = min(input.length, rawEnd + 3200)
                    guard hi > lo else { continue }
                    let samples = try AudioFiles.samples(file: slices, start: lo, end: hi)
                    guard !samples.isEmpty, samples.count < 29 * 16000 else {
                        throw BenchError("Whisper 片段超出安全音频窗口，已停止以免原生引擎截断结果。")
                    }
                    func decode(_ waveform: [Float]) throws -> (pieces: [String], tokens: Int32, language: String?) {
                        try checkCancellation()
                        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw BenchError("无法创建 Whisper 识别流。") }
                        defer { SherpaOnnxDestroyOfflineStream(stream) }
                        waveform.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
                        SherpaOnnxDecodeOfflineStream(recognizer, stream)
                        try checkCancellation()
                        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw BenchError("Whisper 未返回识别结果。") }
                        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
                        let count = result.pointee.count
                        guard count >= 0, count <= 448, count == 0 || result.pointee.tokens_arr != nil else {
                            throw BenchError("Whisper 返回了无效 token 数组。")
                        }
                        var pieces: [String] = []
                        for index in 0..<Int(count) {
                            guard let token = result.pointee.tokens_arr?[index] else { throw BenchError("Whisper token 缺失。") }
                            pieces.append(String(cString: token))
                        }
                        return (pieces, count, result.pointee.lang.map { String(cString: $0) })
                    }
                    stage = "decode_segment"
                    event(stage, detail: "index=\(segments.count) start=\(Double(lo) / 16000) end=\(Double(hi) / 16000)")
                    let segmentStart = ProcessInfo.processInfo.systemUptime
                    var decoded = try decode(samples)
                    var outputGuard = WhisperTurboModel.outputGuardTokenCount(sampleCount: samples.count)
                    metadata["whisper_turbo_last_padding_samples"] = "0"
                    if Int(decoded.tokens) >= outputGuard {
                        // sherpa caps output by input duration. Retry the same speech once with
                        // acoustic silence; keep the VAD interval and discard the capped text.
                        let padding = 29 * 16000 - samples.count
                        let padded = samples + Array(repeating: Float.zero, count: padding)
                        metadata["whisper_turbo_budget_retry_count"] = String((Int(metadata["whisper_turbo_budget_retry_count"] ?? "0") ?? 0) + 1)
                        metadata["whisper_turbo_last_initial_token_count"] = String(decoded.tokens)
                        metadata["whisper_turbo_last_padding_samples"] = String(padding)
                        stage = "retry_output_budget"
                        event(stage, detail: "index=\(segments.count) initial_tokens=\(decoded.tokens) padding_samples=\(padding)")
                        decoded = try decode(padded)
                        outputGuard = WhisperTurboModel.outputGuardTokenCount(sampleCount: padded.count)
                    }
                    metadata["whisper_turbo_last_token_count"] = String(decoded.tokens)
                    metadata["whisper_turbo_last_output_guard"] = String(outputGuard)
                    guard Int(decoded.tokens) < outputGuard else {
                        throw BenchError("Whisper 片段接近原生解码输出上限，结果可能不完整，请用其他模型核对。")
                    }
                    let text = try WhisperByteTokens.text(from: decoded.pieces), language = decoded.language
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw BenchError("Whisper 检测到语音片段但未返回文字，请查看运行日志后重试。")
                    }
                    let item = Segment(id: segments.count, startSeconds: Double(lo) / 16000, endSeconds: Double(hi) / 16000,
                        text: text, elapsedMS: (ProcessInfo.processInfo.systemUptime - segmentStart) * 1000,
                        language: language?.isEmpty == false ? language : nil)
                    segments.append(item); previousEnd = hi
                    metadata["whisper_turbo_completed_segments"] = String(segments.count)
                    await progress(item)
                }
            }
            stage = "scan_vad"; event(stage)
            while input.framePosition < input.length {
                try checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(512, input.length - input.framePosition)))
                guard let pointer = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw BenchError("Whisper 派生音频提前结束。") }
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
            metadata["whisper_turbo_temporary_audio_removed"] = "true"
            stage = "cleanup_token_table"
            try temporaryFiles.remove(tableURL); tokenTable = nil
            metadata["whisper_turbo_temporary_token_table_removed"] = "true"
            metadata["whisper_turbo_completed_segments"] = String(segments.count)
            event("completed", detail: "segments=\(segments.count)")
            return EngineOutput(preparationMS: (ready - start) * 1000,
                transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000, segments: segments, configuration: metadata)
        } catch {
            let nsError = error as NSError
            metadata["whisper_turbo_error_stage"] = stage
            metadata["whisper_turbo_error_domain"] = nsError.domain
            metadata["whisper_turbo_error_code"] = String(nsError.code)
            metadata["whisper_turbo_elapsed_ms"] = String((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if let fileURL = converted {
                do { try temporaryFiles.remove(fileURL); converted = nil; metadata["whisper_turbo_temporary_audio_removed"] = "true" }
                catch { metadata["whisper_turbo_temporary_audio_removed"] = "false"; metadata["whisper_turbo_cleanup_error"] = error.localizedDescription }
            }
            if let tableURL = tokenTable {
                do { try temporaryFiles.remove(tableURL); tokenTable = nil; metadata["whisper_turbo_temporary_token_table_removed"] = "true" }
                catch { metadata["whisper_turbo_temporary_token_table_removed"] = "false"; metadata["whisper_turbo_token_cleanup_error"] = error.localizedDescription }
            }
            event("failed", detail: "stage=\(stage) domain=\(nsError.domain) code=\(nsError.code)")
            throw WhisperTurboSpeechFailure(stage: stage, summary: error.localizedDescription, configuration: metadata)
        }
    }
}
