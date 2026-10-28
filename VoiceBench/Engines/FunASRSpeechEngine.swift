import AVFoundation
import OSLog
import SherpaOnnxC
import VoiceBenchCore

struct FunASRSpeechFailure: LocalizedError, Sendable {
    let stage: String
    let summary: String
    let configuration: [String: String]
    var errorDescription: String? { "Fun-ASR-MLT-Nano 在 \(stage) 阶段失败：\(summary)" }
}

private final class FunASRCStringArena {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func add(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

/// MLT-only native ASR. Empty language hint, no reference/hotwords, no external LID routing.
actor FunASRSpeechEngine {
    private let logger = Logger(subsystem: "com.voicebench.demo", category: "FunASRMLT")

    func transcribe(source: URL, models: URL, runID: UUID, cancellation: CancellationFlag,
                    temporaryFiles: AppTemporaryFiles = .live,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_models"
        var converted: URL?
        var metadata = ["funasr_mlt_model": FunASRModel.version, "funasr_mlt_language_strategy": "model_native_auto",
            "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2", "provider": "cpu", "threads": "2",
            "sample_rate": "16000", "funasr_mlt_feature_dim": "80", "funasr_mlt_model_max_total_len": "512",
            "funasr_mlt_max_new_tokens": String(FunASRModel.maximumNewTokens), "funasr_mlt_temperature": "0.000001", "funasr_mlt_top_p": "1", "funasr_mlt_seed": "0",
            "vad_max_seconds": String(FunASRModel.maximumSpeechSeconds), "vad_min_silence": "0.6", "vad_min_speech": "0",
            "edge_padding_ms": "200", "overlap": "clamped_to_previous_end", "offline": "true",
            "funasr_mlt_timestamps": "vad_region_only", "funasr_mlt_language_labels": "not_exposed_by_native_result",
            "funasr_mlt_itn": "true", "funasr_mlt_context_policy": "budget_retry_v2",
            "funasr_mlt_prompt_tokens": String(FunASRContextBudget.promptTokens),
            "funasr_mlt_budget_safety_tokens": String(FunASRContextBudget.safetyTokens),
            "funasr_mlt_native_stop_reason": "not_exposed; conservative_budget_check",
            "funasr_mlt_prompt_version": "native_transcription_v1", "funasr_mlt_timestamp_policy": "ignore_synthetic_native_timestamps"]
        func checkCancellation() throws { try cancellation.check(); try Task.checkCancellation() }
        func event(_ name: String, detail: String = "") {
            logger.notice("VoiceBenchFunASRMLT run=\(runID.uuidString, privacy: .public) stage=\(name, privacy: .public) \(detail, privacy: .public)")
        }
        var attempts: [[String: String]] = []
        var attemptCount = 0
        var retryCount = 0
        var minimumAcceptedHeadroom: Int?
        func captureBudget(_ budget: FunASRContextBudget, lo: Int64, hi: Int64, depth: Int,
                           tokens: Int?, decision: String) {
            attemptCount += 1
            if decision.hasSuffix("_retry") { retryCount += 1 }
            if decision == "accepted", let tokens {
                let headroom = FunASRContextBudget.capacity - budget.prefillUpperBound - tokens
                minimumAcceptedHeadroom = min(minimumAcceptedHeadroom ?? headroom, headroom)
            }
            let item = ["attempt": String(attemptCount), "start_frame": String(lo), "end_frame": String(hi),
                "depth": String(depth), "audio_tokens_upper_bound": String(budget.audioTokensUpperBound),
                "prompt_tokens": String(FunASRContextBudget.promptTokens), "prefill_upper_bound": String(budget.prefillUpperBound),
                "safe_output_budget": String(budget.availableOutputTokens), "generated_tokens": tokens.map(String.init) ?? "not_decoded",
                "decision": decision]
            if attempts.count < 256 { attempts.append(item) }
            event("context_budget", detail: "attempt=\(attemptCount) prefill_upper=\(budget.prefillUpperBound) generated=\(tokens ?? -1) decision=\(decision)")
        }
        func snapshotBudget() {
            metadata["funasr_mlt_attempt_count"] = String(attemptCount)
            metadata["funasr_mlt_retry_count"] = String(retryCount)
            metadata["funasr_mlt_min_accepted_headroom_tokens"] = minimumAcceptedHeadroom.map(String.init) ?? "not_applicable"
            metadata["funasr_mlt_attempts_omitted"] = String(max(0, attemptCount - attempts.count))
            if let data = try? JSONEncoder().encode(attempts) {
                metadata["funasr_mlt_context_attempts_json"] = String(data: data, encoding: .utf8)
            }
        }
        defer { if let converted { try? temporaryFiles.remove(converted) } }
        do {
            try checkCancellation()
            for name in FunASRModel.requiredFiles {
                guard FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path) else {
                    throw BenchError("模型文件缺失：\(name)，请重新载入 FunASR_MLT_Nano_INT8。")
                }
            }
            stage = "initialize_funasr_mlt"; event(stage)
            let strings = FunASRCStringArena()
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = 16000
            config.feat_config.feature_dim = 80
            config.model_config.funasr_nano.encoder_adaptor = strings.add(models.appendingPathComponent("encoder_adaptor.int8.onnx").path)
            config.model_config.funasr_nano.embedding = strings.add(models.appendingPathComponent("embedding.int8.onnx").path)
            config.model_config.funasr_nano.llm = strings.add(models.appendingPathComponent("llm.int8.onnx").path)
            config.model_config.funasr_nano.tokenizer = strings.add(models.appendingPathComponent("tokenizer", isDirectory: true).path)
            config.model_config.funasr_nano.system_prompt = strings.add(FunASRContextBudget.systemPrompt)
            config.model_config.funasr_nano.user_prompt = strings.add(FunASRContextBudget.userPrompt)
            config.model_config.funasr_nano.language = strings.add("")
            config.model_config.funasr_nano.hotwords = strings.add("")
            config.model_config.funasr_nano.itn = 1
            config.model_config.funasr_nano.max_new_tokens = FunASRModel.maximumNewTokens
            config.model_config.funasr_nano.temperature = 0.000001
            config.model_config.funasr_nano.top_p = 1
            config.model_config.funasr_nano.seed = 0
            config.model_config.num_threads = 2
            config.model_config.provider = strings.add("cpu")
            config.decoding_method = strings.add("greedy_search")
            guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
                throw BenchError("Fun-ASR-MLT-Nano 初始化失败，请检查配套模型和可用内存。")
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
            vadConfig.silero_vad.max_speech_duration = FunASRModel.maximumSpeechSeconds
            vadConfig.sample_rate = 16000; vadConfig.num_threads = 1
            vadConfig.provider = strings.add("cpu")
            guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, 32) else { throw BenchError("FunASR 的 Silero VAD 初始化失败。") }
            defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }
            let ready = ProcessInfo.processInfo.systemUptime
            stage = "convert_audio"; event(stage)
            let fileURL = try temporaryFiles.file(extension: "caf", prefix: "FunASR-")
            converted = fileURL
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            try AudioFiles.convert(source: source, target: fileURL, format: format, cancellation: cancellation)
            let input = try AVAudioFile(forReading: fileURL)
            let slices = try AVAudioFile(forReading: fileURL)
            let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 512)!
            var segments: [Segment] = []
            var previousEnd: Int64 = 0
            var pendingSpan: (lo: Int64, hi: Int64)?
            // Destroy each speculative stream before retrying; never publish its text.
            func decode(_ samples: [Float]) throws -> (text: String, tokens: Int, elapsed: Double) {
                try checkCancellation()
                guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw BenchError("无法创建 FunASR 识别流。") }
                defer { SherpaOnnxDestroyOfflineStream(stream) }
                let decodeStart = ProcessInfo.processInfo.systemUptime
                samples.withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(stream, 16000, $0.baseAddress, Int32($0.count)) }
                SherpaOnnxDecodeOfflineStream(recognizer, stream)
                try checkCancellation()
                guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw BenchError("FunASR 未返回识别结果。") }
                defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
                return (result.pointee.text.map { String(cString: $0) } ?? "", Int(result.pointee.count),
                        (ProcessInfo.processInfo.systemUptime - decodeStart) * 1000)
            }
            func process(lo: Int64, hi: Int64, depth: Int) async throws {
                try checkCancellation()
                stage = "load_segment"
                let samples = try FunASRAudioReader.samples(file: slices, start: lo, end: hi, cancellation: cancellation)
                guard samples.count == Int(hi - lo) else {
                    throw BenchError("FunASR 派生音频读取不完整：预期 \(hi - lo) 帧，实际 \(samples.count) 帧；文件 \(slices.length) 帧，区间 \(lo)–\(hi)。")
                }
                guard samples.allSatisfy({ $0.isFinite }) else {
                    throw BenchError("FunASR 派生音频包含无效采样，未采用本段结果。")
                }
                let budget = FunASRContextBudget(sampleCount: samples.count)
                var decoded: (text: String, tokens: Int, elapsed: Double)?
                if budget.canDecode {
                    stage = "decode_segment"
                    event(stage, detail: "start=\(Double(lo) / 16000) end=\(Double(hi) / 16000) depth=\(depth)")
                    let result = try decode(samples)
                    guard result.tokens >= 0 else { throw BenchError("FunASR 返回了无效的 token 计数。") }
                    decoded = result
                    metadata["funasr_mlt_last_token_count"] = String(result.tokens)
                }
                let safe = decoded.map { budget.accepts(generatedTokens: $0.tokens) } ?? false
                if !safe {
                    stage = "context_budget_retry"
                    let offset = FunASRChunkBoundary.splitOffset(samples: samples, depth: depth)
                    captureBudget(budget, lo: lo, hi: hi, depth: depth, tokens: decoded?.tokens,
                                  decision: offset == nil ? "budget_exhausted" : (decoded == nil ? "prefill_budget_retry" : "near_limit_retry"))
                    guard let offset else {
                        throw BenchError("FunASR 片段无法在 512 上下文内可靠结束；已停止，未采用可能截断的文字。已完成片段保留，请查看预算日志。")
                    }
                    let cut = lo + Int64(offset)
                    event("split_retry", detail: "start=\(lo) cut=\(cut) end=\(hi) depth=\(depth)")
                    try await process(lo: lo, hi: cut, depth: depth + 1)
                    try await process(lo: cut, hi: hi, depth: depth + 1)
                    return
                }
                guard let decoded, !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BenchError("FunASR 检测到语音片段但未返回文字，请查看运行日志后重试。")
                }
                captureBudget(budget, lo: lo, hi: hi, depth: depth, tokens: decoded.tokens, decision: "accepted")
                let item = Segment(id: segments.count, startSeconds: Double(lo) / 16000, endSeconds: Double(hi) / 16000,
                    text: decoded.text, elapsedMS: decoded.elapsed)
                segments.append(item)
                metadata["funasr_mlt_completed_segments"] = String(segments.count)
                await progress(item)
            }
            func processSpan(_ span: (lo: Int64, hi: Int64)) async throws {
                let lo = max(previousEnd, max(0, span.lo - 3200))
                let hi = min(input.length, span.hi + 3200)
                guard hi > lo else { return }
                // Merging may extend a 32s span by padding. Clamp padding, never speech.
                let paddedEnd = hi - lo <= 32 * 16000 ? hi : min(input.length, span.hi)
                let paddedStart = paddedEnd - lo <= 32 * 16000 ? lo : max(previousEnd, span.lo)
                try await process(lo: paddedStart, hi: paddedEnd, depth: 0)
                previousEnd = paddedEnd
            }
            func drain() async throws {
                while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                    try checkCancellation()
                    guard let speech = SherpaOnnxVoiceActivityDetectorFront(vad) else { throw BenchError("无法读取 FunASR VAD 片段。") }
                    let rawStart = Int64(speech.pointee.start)
                    let rawEnd = rawStart + Int64(speech.pointee.n)
                    SherpaOnnxDestroySpeechSegment(speech)
                    SherpaOnnxVoiceActivityDetectorPop(vad)
                    let next = (lo: max(0, rawStart), hi: min(input.length, rawEnd))
                    guard next.hi > next.lo else { continue }
                    if let pending = pendingSpan {
                        if FunASRChunkBoundary.shouldMerge(previousStart: pending.lo, previousEnd: pending.hi,
                                                          nextStart: next.lo, nextEnd: next.hi) {
                            pendingSpan = (pending.lo, max(pending.hi, next.hi))
                            event("merge_short_tail", detail: "start=\(pending.lo) end=\(next.hi)")
                            continue
                        }
                        try await processSpan(pending)
                    }
                    pendingSpan = next
                }
            }
            stage = "scan_vad"; event(stage)
            while input.framePosition < input.length {
                try checkCancellation()
                let count = Int(min(512, input.length - input.framePosition))
                var window = try FunASRAudioReader.read(file: input, frameCount: count, buffer: buffer, cancellation: cancellation)
                window += Array(repeating: 0, count: 512 - window.count)
                window.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, Int32($0.count)) }
                try await drain()
                stage = "scan_vad"
            }
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            try await drain()
            if let pending = pendingSpan { try await processSpan(pending) }
            try checkCancellation()
            stage = "cleanup_audio"
            try temporaryFiles.remove(fileURL); converted = nil
            metadata["funasr_mlt_temporary_audio_removed"] = "true"
            metadata["funasr_mlt_completed_segments"] = String(segments.count)
            snapshotBudget()
            event("completed", detail: "segments=\(segments.count)")
            return EngineOutput(preparationMS: (ready - start) * 1000,
                transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000, segments: segments, configuration: metadata)
        } catch {
            snapshotBudget()
            let nsError = error as NSError
            metadata["funasr_mlt_error_stage"] = stage
            metadata["funasr_mlt_error_domain"] = nsError.domain
            metadata["funasr_mlt_error_code"] = String(nsError.code)
            metadata["funasr_mlt_elapsed_ms"] = String((ProcessInfo.processInfo.systemUptime - start) * 1000)
            if let fileURL = converted {
                do { try temporaryFiles.remove(fileURL); converted = nil; metadata["funasr_mlt_temporary_audio_removed"] = "true" }
                catch { metadata["funasr_mlt_temporary_audio_removed"] = "false"; metadata["funasr_mlt_cleanup_error"] = error.localizedDescription }
            }
            event("failed", detail: "stage=\(stage) domain=\(nsError.domain) code=\(nsError.code)")
            throw FunASRSpeechFailure(stage: stage, summary: error.localizedDescription, configuration: metadata)
        }
    }
}
