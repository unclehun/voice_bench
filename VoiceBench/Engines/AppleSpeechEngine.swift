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
    private func locale(for identifier: String) async -> Locale? {
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    func supportedLocaleIdentifiers() async -> [String] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return Array(Set(await SpeechTranscriber.supportedLocales.map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })).sorted()
    }

    func capability(localeIdentifier: String) async -> SpeechCapability {
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapability(available: false, installed: false, detail: "当前设备不支持 SpeechTranscriber。")
        }
        guard let locale = await locale(for: localeIdentifier) else {
            return SpeechCapability(available: false, installed: false,
                detail: "系统不支持默认语言 \(AppleSpeechSettings.displayName(localeIdentifier))，请在设置中选择其他语言。")
        }
        let status = await AssetInventory.status(forModules: [transcriber(locale)])
        return SpeechCapability(available: true, installed: status == .installed, locale: locale.identifier,
            detail: "\(AppleSpeechSettings.displayName(locale.identifier))：\(status == .installed ? "已就绪" : String(describing: status))")
    }

    func prepare(localeIdentifier: String, progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw BenchError("当前设备不支持 SpeechTranscriber。") }
        try Task.checkCancellation()
        guard let locale = await locale(for: localeIdentifier) else {
            throw BenchError("Apple Speech 不支持默认语言 \(AppleSpeechSettings.displayName(localeIdentifier))。")
        }
        let module = transcriber(locale)
        if await AssetInventory.status(forModules: [module]) != .installed {
            // false means already reserved; unsupported/quota errors are thrown.
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
            guard await AssetInventory.status(forModules: [module]) == .installed else {
                throw BenchError("默认语言语音资源尚未安装完成，请重试。")
            }
        }
        await progress(1)
    }

    func transcribe(source: URL, localeIdentifier: String, runID: UUID, cancellation: CancellationFlag,
                    temporaryFiles: AppTemporaryFiles = .live,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let diagnostics = AppleSpeechDiagnostics(runID: runID)
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_support"
        var converted: URL?
        diagnostics.record(["requested_locale": localeIdentifier, "apple_input_pipeline": "pcm_full_recording_v3",
                            "apple_language_strategy": "configured_locale_full_recording_v1",
                            "apple_external_language_detection": "false", "apple_audio_scope": "full_recording",
                            "apple_session_count": "0"])
        defer { if let converted { try? temporaryFiles.remove(converted) } }
        do {
            try cancellation.check(); try Task.checkCancellation()
            let settings = try AppleSpeechSettings(localeIdentifier: localeIdentifier)
            diagnostics.record(settings.runConfiguration)
            guard SpeechTranscriber.isAvailable else { throw BenchError("当前设备不支持 SpeechTranscriber。") }
            stage = "inspect_source"
            let sourceFile = try AVAudioFile(forReading: source)
            diagnostics.event(stage, metadata: ["apple_source_format": PCMFileReader.describe(sourceFile.fileFormat),
                                               "apple_source_frames": String(sourceFile.length)])
            guard sourceFile.length > 0 else { throw BenchError("录音没有可供识别的音频帧。") }
            stage = "select_locale"
            guard let locale = await locale(for: settings.localeIdentifier) else {
                throw BenchError("Apple Speech 不支持默认语言 \(AppleSpeechSettings.displayName(settings.localeIdentifier))，请在设置中选择其他语言。")
            }
            diagnostics.record(["apple_locale": locale.identifier])
            let module = transcriber(locale)
            stage = "check_assets"
            let status = await AssetInventory.status(forModules: [module])
            diagnostics.event(stage, metadata: ["locale": locale.identifier, "apple_asset_status": String(describing: status)])
            guard status == .installed else {
                throw BenchError("请到设置准备默认语言 \(AppleSpeechSettings.displayName(locale.identifier)) 的苹果语音资源后重试。")
            }
            stage = "select_format"
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw BenchError("系统没有返回兼容的音频格式。")
            }
            stage = "convert_audio"; diagnostics.event(stage)
            let target = try temporaryFiles.file(extension: "caf")
            converted = target
            try AudioFiles.convert(source: source, target: target, format: format, cancellation: cancellation)
            let output = try await transcribeAudio(converted: target, module: module, format: format,
                localeIdentifier: locale.identifier, cancellation: cancellation, diagnostics: diagnostics, progress: progress)
            stage = "cleanup_audio"
            try temporaryFiles.remove(target)
            converted = nil
            diagnostics.event("completed", metadata: ["apple_final_segments": String(output.segments.count),
                                                        "apple_temporary_audio_removed": "true"])
            return EngineOutput(preparationMS: output.preparationMS,
                                transcriptionMS: max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000 - output.preparationMS),
                                segments: output.segments, configuration: diagnostics.configuration())
        } catch {
            if !(error is AppleSpeechFailure) { diagnostics.failure(error, stage: stage) }
            var removed = true
            if let converted {
                do { try temporaryFiles.remove(converted) }
                catch { removed = false; diagnostics.failure(error, stage: "cleanup_audio") }
            }
            diagnostics.record(["apple_temporary_audio_removed": String(removed)])
            if let failure = error as? AppleSpeechFailure {
                throw AppleSpeechFailure(stage: failure.stage, summary: failure.summary, configuration: diagnostics.configuration())
            }
            throw diagnostics.wrappedFailure(error, stage: stage)
        }
    }

    private func transcribeAudio(converted: URL, module: SpeechTranscriber, format: AVAudioFormat,
                                 localeIdentifier: String, cancellation: CancellationFlag,
                                 diagnostics: AppleSpeechDiagnostics,
                                 progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_support"
        diagnostics.event(stage)
        do {
            try Task.checkCancellation()
            try cancellation.check()
            diagnostics.record(["apple_selected_format": PCMFileReader.describe(format),
                                "input_sample_rate": String(format.sampleRate), "input_channels": String(format.channelCount)])
            let session = AppleSpeechSession(module: module)
            diagnostics.record(["apple_session_count": "1"])
            return try await withTaskCancellationHandler {
                var reader: PCMFileReader?
                var consumer: Task<[Segment], Error>?
                do {
                    stage = "prepare_analyzer"
                    diagnostics.event(stage, metadata: ["apple_selected_format": PCMFileReader.describe(format)])
                    try await session.prepare(in: format)
                    let ready = ProcessInfo.processInfo.systemUptime
                    diagnostics.record(["apple_preparation_ms": String((ready - start) * 1000)])
                    stage = "open_pcm"
                    diagnostics.event(stage)
                    let input = try PCMFileReader(url: converted, format: format, cancellation: cancellation,
                                                  inspect: { diagnostics.record($0) })
                    reader = input
                    diagnostics.event("pcm_opened", metadata: input.metadata)

                    // Results must be consumed concurrently, but audio buffers are pulled one at a time.
                    let results = Task { () throws -> [Segment] in
                        var segments: [Segment] = []
                        do {
                            for try await result in module.results {
                                try Task.checkCancellation()
                                try cancellation.check()
                                if !result.isFinal { continue }
                                let lo = input.startSeconds + CMTimeGetSeconds(result.range.start)
                                let hi = input.startSeconds + CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                                guard lo.isFinite, hi.isFinite, hi >= lo else { throw BenchError("Apple 返回了无效的片段时间。") }
                                let item = Segment(id: segments.count,
                                    startSeconds: min(input.endSeconds, max(input.startSeconds, lo)),
                                    endSeconds: min(input.endSeconds, max(input.startSeconds, hi)),
                                    text: String(result.text.characters), language: Locale(identifier: localeIdentifier).languageCode)
                                segments.append(item)
                                diagnostics.record(["apple_final_segments": String(segments.count)])
                                await progress(item)
                            }
                            diagnostics.event("results_ended", metadata: ["apple_final_segments": String(segments.count)])
                            return segments
                        } catch {
                            diagnostics.failure(error, stage: "receive_results")
                            if cancellation.isCancelled || Task.isCancelled { await session.cancel() }
                            else { await session.failed() }
                            throw error
                        }
                    }
                    consumer = results
                    stage = "analyze_audio"
                    diagnostics.event(stage)
                    let lastTime = try await session.analyze(AppleAudioInputSequence(reader: input, diagnostics: diagnostics))
                    try Task.checkCancellation()
                    try cancellation.check()
                    let inputState = await input.snapshot()
                    diagnostics.event("input_consumed", metadata: inputState)
                    guard inputState["apple_input_eof"] == "true", let lastTime,
                          lastTime.isNumeric, CMTimeGetSeconds(lastTime) >= 0 else {
                        throw BenchError("Apple Speech 未完整消费音频或没有返回有效结束时间。")
                    }
                    stage = "finalize_analysis"
                    diagnostics.event(stage, metadata: ["apple_last_sample_seconds": String(CMTimeGetSeconds(lastTime))])
                    try await session.finish(through: lastTime)
                    stage = "collect_results"
                    diagnostics.event(stage)
                    let segments = try await results.value
                    try cancellation.check()
                    await input.close()
                    return EngineOutput(preparationMS: (ready - start) * 1000,
                                        transcriptionMS: (ProcessInfo.processInfo.systemUptime - ready) * 1000,
                                        segments: segments, configuration: diagnostics.configuration())
                } catch {
                    diagnostics.failure(error, stage: stage)
                    consumer?.cancel()
                    await session.cancel()
                    if let consumer { _ = try? await consumer.value }
                    if let reader {
                        diagnostics.record(await reader.snapshot())
                        await reader.close()
                    }
                    throw error
                }
            } onCancel: {
                cancellation.cancel()
                diagnostics.event("cancel_requested")
                Task { await session.cancel() }
            }
        } catch {
            throw diagnostics.wrappedFailure(error, stage: stage)
        }
    }

    func releaseReservations() async {
        // These are this app's reservations, not permission to delete shared system model files.
        for locale in await AssetInventory.reservedLocales {
            _ = await AssetInventory.release(reservedLocale: locale)
        }
    }

    private func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    }

}

/// The analyzer requests the next block only when needed; no unbounded AsyncStream queue.
private struct AppleAudioInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let reader: PCMFileReader
    let diagnostics: AppleSpeechDiagnostics

    struct AsyncIterator: AsyncIteratorProtocol {
        let reader: PCMFileReader
        let diagnostics: AppleSpeechDiagnostics
        private var chunks = 0

        init(reader: PCMFileReader, diagnostics: AppleSpeechDiagnostics) {
            self.reader = reader; self.diagnostics = diagnostics
        }

        mutating func next() async throws -> AnalyzerInput? {
            do {
                guard let chunk = try await reader.next() else {
                    diagnostics.event("input_eof", metadata: await reader.snapshot())
                    return nil
                }
                chunks += 1
                let state = await reader.snapshot()
                diagnostics.record(state)
                if chunks == 1 || chunks % 256 == 0 || chunk.buffer.frameLength < 4096 {
                    diagnostics.event("input_progress", metadata: state)
                }
                let time = CMTime(value: chunk.startFrame, timescale: chunk.sampleRate)
                return AnalyzerInput(buffer: chunk.buffer, bufferStartTime: time)
            } catch {
                diagnostics.record(await reader.snapshot())
                diagnostics.failure(error, stage: "read_audio")
                throw error
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(reader: reader, diagnostics: diagnostics) }
}

/// Errors from SpeechAnalyzer finish its session automatically. Serialize explicit cancellation
/// with that state so cleanup does not repeatedly cancel an already finished analyzer.
private actor AppleSpeechSession {
    private let analyzer: SpeechAnalyzer
    private var finished = false

    init(module: SpeechTranscriber) { analyzer = SpeechAnalyzer(modules: [module]) }

    func prepare(in format: AVAudioFormat) async throws {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        do { try await analyzer.prepareToAnalyze(in: format) }
        catch { finished = true; throw error }
    }

    func analyze(_ sequence: AppleAudioInputSequence) async throws -> CMTime? {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        do { return try await analyzer.analyzeSequence(sequence) }
        catch { finished = true; throw error }
    }

    func finish(through time: CMTime) async throws {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        do { try await analyzer.finalizeAndFinish(through: time); finished = true }
        catch { finished = true; throw error }
    }

    func failed() { finished = true }

    func cancel() async {
        guard !finished else { return }
        finished = true
        await analyzer.cancelAndFinishNow()
    }
}
