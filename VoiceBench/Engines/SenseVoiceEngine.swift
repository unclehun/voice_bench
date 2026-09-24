import AVFoundation
import SherpaOnnxC
import VoiceBenchCore

/// Owns C strings until both native models have been destroyed.
private final class CStringArena {
    var values: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        values.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { values.forEach { free($0) } }
}

struct EngineOutput: Sendable {
    var preparationMS: Double
    var transcriptionMS: Double
    var segments: [Segment]
    var configuration: [String: String]
    var text: String { segments.map(\.text).joined(separator: "\n") }
}

actor SenseVoiceEngine {
    func transcribe(source: URL, models: URL, language: String, lowMemory: Bool,
                    cancellation: CancellationFlag,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let start = ProcessInfo.processInfo.systemUptime
        try cancellation.check()
        let arena = CStringArena()
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.tokens = arena.add(models.appendingPathComponent("tokens.txt").path)
        config.model_config.sense_voice.model = arena.add(models.appendingPathComponent("model.int8.onnx").path)
        config.model_config.sense_voice.language = arena.add(language)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.num_threads = lowMemory ? 1 : 2
        config.model_config.provider = arena.add("cpu")
        config.model_config.model_type = arena.add("sense_voice")
        config.decoding_method = arena.add("greedy_search")
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw BenchError("SenseVoice 初始化失败，请检查模型文件及版本。")
        }
        defer { SherpaOnnxDestroyOfflineRecognizer(recognizer); withExtendedLifetime(arena) {} }
        var vadConfig = SherpaOnnxVadModelConfig()
        vadConfig.silero_vad.model = arena.add(models.appendingPathComponent("silero_vad.onnx").path)
        vadConfig.silero_vad.threshold = 0.5
        vadConfig.silero_vad.min_silence_duration = 0.6
        vadConfig.silero_vad.min_speech_duration = 0.0
        vadConfig.silero_vad.window_size = 512
        vadConfig.silero_vad.max_speech_duration = lowMemory ? 12 : 25
        vadConfig.sample_rate = 16000
        vadConfig.num_threads = 1
        vadConfig.provider = arena.add("cpu")
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 32) else { throw BenchError("Silero VAD 初始化失败。") }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
        let ready = ProcessInfo.processInfo.systemUptime
        let converted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: converted) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        try AudioFiles.convert(source: source, target: converted, format: format, cancellation: cancellation)
        let input = try AVAudioFile(forReading: converted)
        let sliceFile = try AVAudioFile(forReading: converted)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 512)!
        var segments: [Segment] = []
        // Protect segment edges without overlapping the preceding segment's decoded samples.
        var previousEnd: Int64 = 0
        func drain() async throws {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                try cancellation.check()
                guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw BenchError("无法读取 VAD 片段。") }
                let rawStart = Int64(segment.pointee.start)
                let rawEnd = rawStart + Int64(segment.pointee.n)
                SherpaOnnxDestroySpeechSegment(segment)
                SherpaOnnxVoiceActivityDetectorPop(vad)
                let lo = max(previousEnd, max(0, rawStart - 3200))
                let hi = min(input.length, rawEnd + 3200)
                if hi <= lo { continue }
                let samples = try AudioFiles.samples(file: sliceFile, start: lo, end: hi)
                guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw BenchError("无法创建识别流。") }
                defer { SherpaOnnxDestroyOfflineStream(stream) }
                let segmentStart = ProcessInfo.processInfo.systemUptime
                samples.withUnsafeBufferPointer { data in
                    SherpaOnnxAcceptWaveformOffline(stream, 16000, data.baseAddress, Int32(data.count))
                }
                SherpaOnnxDecodeOfflineStream(recognizer, stream)
                try cancellation.check()
                guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw BenchError("SenseVoice 未返回结果。") }
                let text = result.pointee.text.map { String(cString: $0) } ?? ""
                SherpaOnnxDestroyOfflineRecognizerResult(result)
                let item = Segment(id: segments.count, startSeconds: Double(lo) / 16000, endSeconds: Double(hi) / 16000,
                                   text: text, elapsedMS: (ProcessInfo.processInfo.systemUptime - segmentStart) * 1000)
                segments.append(item); previousEnd = hi
                await progress(item)
            }
        }
        while input.framePosition < input.length {
            try cancellation.check()
            try input.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            // Silero consumes fixed-size windows; zero-pad only the final partial window.
            var window = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            window += Array(repeating: 0, count: 512 - window.count)
            window.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
            try await drain()
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        try await drain()
        try cancellation.check()
        return EngineOutput(preparationMS: (ready - start) * 1000,
                            transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000, segments: segments,
                            configuration: ["sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2", "provider": "cpu", "language": language,
                                            "threads": lowMemory ? "1" : "2", "sample_rate": "16000", "itn": "true",
                                            "vad_max_seconds": lowMemory ? "12" : "25", "vad_min_silence": "0.6",
                                            "vad_min_speech": "0", "edge_padding_ms": "200", "overlap": "clamped_to_previous_end"])
    }
}
