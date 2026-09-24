import AVFoundation
import Speech
import VoiceBenchCore

struct SpeechCapability: Sendable {
    var available: Bool
    var installed: Bool
    var locale: String?
    var detail: String
}

actor AppleSpeechEngine {
    func capability() async -> SpeechCapability {
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapability(available: false, installed: false, detail: "当前设备不支持 SpeechTranscriber。")
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            return SpeechCapability(available: false, installed: false, detail: "系统未提供对应的普通话 locale。")
        }
        let module = transcriber(locale)
        let status = await AssetInventory.status(forModules: [module])
        return SpeechCapability(available: true, installed: status == .installed, locale: locale.identifier,
                                detail: status == .installed ? "中文资源已就绪" : "中文资源状态：\(status)")
    }

    func prepare(progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw BenchError("当前设备或中文不支持 SpeechTranscriber。")
        }
        let module = transcriber(locale)
        if await AssetInventory.status(forModules: [module]) == .installed { return }
        // false means already reserved, not failure; unsupported/quota errors are thrown.
        _ = try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let monitor = Task {
                while !Task.isCancelled {
                    await progress(request.progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            defer { monitor.cancel() }
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw BenchError("语音资源尚未安装完成，请重试。") }
        await progress(1)
    }

    func transcribe(source: URL, cancellation: CancellationFlag,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        try cancellation.check()
        let start = ProcessInfo.processInfo.systemUptime
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw BenchError("当前设备或中文不支持 SpeechTranscriber；未使用替代引擎。")
        }
        let module = transcriber(locale)
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw BenchError("请先点击“准备苹果中文资源”，再进行离线评测。") }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw BenchError("系统没有返回兼容的音频格式。") }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let ready = ProcessInfo.processInfo.systemUptime
        let converted = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: converted) }
        // Consume results concurrently with file analysis; save only finalized text.
        let consumer = Task { () throws -> [Segment] in
            var segments: [Segment] = []
            for try await result in module.results {
                try cancellation.check()
                if !result.isFinal { continue }
                let item = Segment(id: segments.count,
                                   startSeconds: CMTimeGetSeconds(result.range.start),
                                   endSeconds: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                                   text: String(result.text.characters))
                segments.append(item)
                await progress(item)
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                try AudioFiles.convert(source: source, target: converted, format: format, cancellation: cancellation)
                let audioFile = try AVAudioFile(forReading: converted, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                _ = try await analyzer.analyzeSequence(from: audioFile)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let segments = try await consumer.value
                try cancellation.check()
                return EngineOutput(preparationMS: (ready - start) * 1000,
                                    transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000,
                                    segments: segments, configuration: ["locale": locale.identifier,
                                        "input_sample_rate": String(format.sampleRate), "input_channels": String(format.channelCount),
                                        "offline": "true", "module": "SpeechTranscriber", "results": "final_only"])
            } catch {
                consumer.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await consumer.value
                throw error
            }
        } onCancel: {
            cancellation.cancel()
            consumer.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }
}
