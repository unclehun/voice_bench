import AVFoundation
import OSLog
import SherpaOnnxC
import VoiceBenchCore

struct LanguageIDFailure: LocalizedError, Sendable {
    var stage: String
    var summary: String
    var configuration: [String: String]
    var errorDescription: String? { "语言检测在 \(stage) 阶段失败：\(summary)" }
}

private final class LanguageStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

/// Whisper is used only for language ID; Apple still produces the Apple transcript.
/// Native model ownership ends before the caller starts SpeechAnalyzer.
actor WhisperLanguageDetector {
    private let logger = Logger(subsystem: "com.voicebench.demo", category: "LanguageID")

    func detect(source: URL, models: URL, runID: UUID,
                cancellation: CancellationFlag, temporaryFiles: AppTemporaryFiles = .live,
                progress: @escaping @Sendable (Int) async -> Void) async throws -> LanguageDetection {
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "initialize_whisper"
        var completedWindows = 0
        func event(_ name: String, detail: String = "") {
            logger.notice("VoiceBenchLanguageID run=\(runID.uuidString, privacy: .public) stage=\(name, privacy: .public) \(detail, privacy: .public)")
        }
        do {
            try cancellation.check(); try Task.checkCancellation()
            event(stage)
            let strings = LanguageStrings()
            var config = SherpaOnnxSpokenLanguageIdentificationConfig()
            config.whisper.encoder = strings.add(models.appendingPathComponent("tiny-encoder.int8.onnx").path)
            config.whisper.decoder = strings.add(models.appendingPathComponent("tiny-decoder.int8.onnx").path)
            config.num_threads = 2
            config.provider = strings.add("cpu")
            guard let identifier = SherpaOnnxCreateSpokenLanguageIdentification(&config) else {
                throw BenchError("Whisper Tiny 初始化失败，请重新导入配套 INT8 模型。")
            }
            defer { SherpaOnnxDestroySpokenLanguageIdentification(identifier); withExtendedLifetime(strings) {} }
            stage = "initialize_vad"
            var vadConfig = SherpaOnnxVadModelConfig()
            vadConfig.silero_vad.model = strings.add(models.appendingPathComponent("silero_vad.onnx").path)
            vadConfig.silero_vad.threshold = 0.5
            vadConfig.silero_vad.min_silence_duration = 0.6
            vadConfig.silero_vad.min_speech_duration = 0
            vadConfig.silero_vad.window_size = 512
            vadConfig.silero_vad.max_speech_duration = 25
            vadConfig.sample_rate = 16000
            vadConfig.num_threads = 1
            vadConfig.provider = strings.add("cpu")
            guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 32) else {
                throw BenchError("语言检测的 Silero VAD 初始化失败。")
            }
            defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
            let ready = ProcessInfo.processInfo.systemUptime
            stage = "convert_audio"; event(stage)
            let converted = try temporaryFiles.file(extension: "caf", prefix: "LanguageID-")
            defer { try? temporaryFiles.remove(converted) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            try AudioFiles.convert(source: source, target: converted, format: format, cancellation: cancellation)
            let input = try AVAudioFile(forReading: converted)
            let slices = try AVAudioFile(forReading: converted)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 512)!
            let duration = Double(input.length) / 16000
            var spans: [DetectedSpeechSpan] = []
            var previousEnd: Int64 = 0
            func drain() async throws {
                while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                    try cancellation.check(); try Task.checkCancellation()
                    guard let item = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw BenchError("无法读取语言检测的 VAD 片段。") }
                    let lo = max(previousEnd, max(0, Int64(item.pointee.start)))
                    let hi = min(input.length, Int64(item.pointee.start) + Int64(item.pointee.n))
                    SherpaOnnxDestroySpeechSegment(item)
                    SherpaOnnxVoiceActivityDetectorPop(vad)
                    guard hi > lo else { continue }
                    var windows: [LanguageWindow] = []
                    var cursor = lo
                    while cursor < hi {
                        try cancellation.check(); try Task.checkCancellation()
                        // 5 s windows; attach a <1 s tail to avoid an extra unreliable tiny vote.
                        var end = min(hi, cursor + 5 * 16000)
                        if hi - end < 16000 { end = hi }
                        stage = "identify_window"
                        let samples = try AudioFiles.samples(file: slices, start: cursor, end: end)
                        guard let stream = SherpaOnnxSpokenLanguageIdentificationCreateOfflineStream(identifier) else {
                            throw BenchError("无法创建 Whisper 语言检测流。")
                        }
                        defer { SherpaOnnxDestroyOfflineStream(stream) }
                        samples.withUnsafeBufferPointer {
                            SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count))
                        }
                        guard let result = SherpaOnnxSpokenLanguageIdentificationCompute(identifier, stream) else {
                            throw BenchError("Whisper 未返回语言检测结果。")
                        }
                        let code = LanguageRouting.normalized(result.pointee.lang.map { String(cString: $0) })
                        SherpaOnnxDestroySpokenLanguageIdentificationResult(result)
                        try cancellation.check(); try Task.checkCancellation()
                        windows.append(LanguageWindow(startSeconds: Double(cursor) / 16000,
                                                      endSeconds: Double(end) / 16000, language: code))
                        completedWindows += 1
                        event("window", detail: "index=\(completedWindows) start=\(Double(cursor) / 16000) end=\(Double(end) / 16000) language=\(code ?? "und")")
                        await progress(completedWindows)
                        cursor = end
                    }
                    spans.append(DetectedSpeechSpan(startSeconds: Double(lo) / 16000, endSeconds: Double(hi) / 16000, windows: windows))
                    previousEnd = hi
                }
            }
            stage = "scan_vad"
            while input.framePosition < input.length {
                try cancellation.check(); try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(512, input.length - input.framePosition)))
                guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                    throw BenchError("语言检测派生音频提前结束。")
                }
                var window = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
                window += Array(repeating: 0, count: 512 - window.count)
                window.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
                try await drain()
                stage = "scan_vad"
            }
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            try await drain()
            let plan = LanguageDetection(preparationMS: (ready - start) * 1000,
                                         detectionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000,
                                         durationSeconds: duration, spans: spans)
            event("completed", detail: "spans=\(spans.count) regions=\(plan.regions.count) languages=\(plan.languages.joined(separator: ",")) elapsed_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
            return plan
        } catch {
            let nsError = error as NSError
            event("failed", detail: "stage=\(stage) domain=\(nsError.domain) code=\(nsError.code)")
            throw LanguageIDFailure(stage: stage, summary: error.localizedDescription, configuration: [
                "lid_error_stage": stage, "lid_error_domain": nsError.domain, "lid_error_code": String(nsError.code),
                "lid_completed_windows": String(completedWindows),
                "lid_elapsed_ms": String((ProcessInfo.processInfo.systemUptime - start) * 1000)])
        }
    }
}
