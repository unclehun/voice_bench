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
    private func locale(for language: String) async -> Locale? {
        let identifier = ["zh": "zh-CN", "en": "en-US", "yue": "yue-Hant-HK"][language] ?? language
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    func capability(languages: [String] = ["zh", "en"]) async -> SpeechCapability {
        guard SpeechTranscriber.isAvailable else {
            return SpeechCapability(available: false, installed: false, detail: "当前设备不支持 SpeechTranscriber。")
        }
        var details: [String] = []
        var allInstalled = true
        for code in languages {
            guard let locale = await locale(for: code) else {
                return SpeechCapability(available: false, installed: false, detail: "系统不支持检测到的语言：\(LanguageRouting.name(code))（\(code)）。")
            }
            let status = await AssetInventory.status(forModules: [transcriber(locale)])
            allInstalled = allInstalled && status == .installed
            details.append("\(LanguageRouting.name(code))：\(status == .installed ? "已就绪" : String(describing: status))")
        }
        return SpeechCapability(available: true, installed: allInstalled, detail: details.joined(separator: "；"))
    }

    func prepare(languages: [String] = ["zh", "en"], progress: @escaping @Sendable (Double) async -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw BenchError("当前设备不支持 SpeechTranscriber。") }
        let codes = Array(Set(languages)).sorted()
        for (index, code) in codes.enumerated() {
            try Task.checkCancellation()
            guard let locale = await locale(for: code) else { throw BenchError("Apple Speech 不支持 \(LanguageRouting.name(code))（\(code)）。") }
            let module = transcriber(locale)
            if await AssetInventory.status(forModules: [module]) != .installed {
                // false means already reserved; unsupported/quota errors are thrown.
                _ = try await AssetInventory.reserve(locale: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    let monitor = Task {
                        while !Task.isCancelled {
                            await progress((Double(index) + request.progress.fractionCompleted) / Double(codes.count))
                            try? await Task.sleep(nanoseconds: 250_000_000)
                        }
                    }
                    defer { monitor.cancel() }
                    try await request.downloadAndInstall()
                }
                guard await AssetInventory.status(forModules: [module]) == .installed else {
                    throw BenchError("\(LanguageRouting.name(code))语音资源尚未安装完成，请重试。")
                }
            }
            await progress(Double(index + 1) / Double(codes.count))
        }
    }

    func transcribe(source: URL, plan: LanguageDetection, runID: UUID, cancellation: CancellationFlag,
                    temporaryFiles: AppTemporaryFiles = .live,
                    progress: @escaping @Sendable (Segment) async -> Void) async throws -> EngineOutput {
        let diagnostics = AppleSpeechDiagnostics(runID: runID)
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "check_support"
        var converted: [String: URL] = [:]
        diagnostics.record(["apple_input_pipeline": "pcm_language_regions_v2", "apple_language_strategy": plan.strategy,
                            "apple_languages": plan.languages.joined(separator: ","), "apple_region_count": String(plan.regions.count)])
        defer { for url in converted.values { try? temporaryFiles.remove(url) } }
        do {
            try cancellation.check(); try Task.checkCancellation()
            guard SpeechTranscriber.isAvailable else { throw BenchError("当前设备不支持 SpeechTranscriber。") }
            stage = "inspect_source"
            let sourceFile = try AVAudioFile(forReading: source)
            diagnostics.event(stage, metadata: ["apple_source_format": PCMFileReader.describe(sourceFile.fileFormat),
                                               "apple_source_frames": String(sourceFile.length)])
            // Check every route up front, so unsupported/missing languages cannot produce a misleading partial success.
            for code in plan.languages {
                guard let locale = await locale(for: code) else {
                    throw BenchError("Apple Speech 不支持检测到的语言 \(LanguageRouting.name(code))（\(code)）。")
                }
                stage = "check_assets"
                let status = await AssetInventory.status(forModules: [transcriber(locale)])
                diagnostics.event(stage, metadata: ["locale": locale.identifier, "apple_asset_status": String(describing: status)])
                guard status == .installed else {
                    throw BenchError("检测到\(LanguageRouting.name(code))，请点击“准备苹果语言资源”后重试；本次没有使用云端识别。")
                }
            }
            stage = "check_language_plan"
            guard !plan.regions.contains(where: { $0.language == nil }) else {
                throw BenchError("部分语音未能检测语言。请尝试更长、更清晰的语音；检测明细已保存在本次结果中。")
            }
            var segments: [Segment] = []
            var preparationMS: Double = 0
            var routes: [String] = []
            for (index, region) in plan.regions.enumerated() {
                try cancellation.check(); try Task.checkCancellation()
                guard let code = region.language, let locale = await locale(for: code) else { throw BenchError("语言路由无效。") }
                let module = transcriber(locale)
                stage = "select_format"
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                    throw BenchError("系统没有返回兼容的音频格式。")
                }
                diagnostics.event("region", metadata: ["apple_region_index": String(index), "locale": locale.identifier,
                    "apple_region_start": String(region.startSeconds), "apple_region_end": String(region.endSeconds),
                    "apple_region_decision": region.decision])
                routes.append("\(index):\(locale.identifier):\(region.startSeconds)-\(region.endSeconds):\(region.decision)")
                diagnostics.record(["apple_locale_routes": routes.joined(separator: " | ")])
                let key = PCMFileReader.describe(format)
                let target: URL
                if let existing = converted[key] { target = existing }
                else {
                    stage = "convert_audio"; diagnostics.event(stage)
                    target = try temporaryFiles.file(extension: "caf")
                    converted[key] = target
                    try AudioFiles.convert(source: source, target: target, format: format, cancellation: cancellation)
                }
                let output = try await transcribeRegion(converted: target, module: module, format: format,
                    region: region, segmentOffset: segments.count, cancellation: cancellation,
                    diagnostics: diagnostics, progress: progress)
                segments += output.segments
                preparationMS += output.preparationMS
            }
            stage = "cleanup_audio"
            for url in converted.values { try temporaryFiles.remove(url) }
            converted.removeAll()
            diagnostics.event("completed", metadata: ["apple_final_segments": String(segments.count), "apple_temporary_audio_removed": "true"])
            return EngineOutput(preparationMS: preparationMS,
                                transcriptionMS: (ProcessInfo.processInfo.systemUptime - start) * 1000 - preparationMS,
                                segments: segments, configuration: diagnostics.configuration())
        } catch {
            if !(error is AppleSpeechFailure) { diagnostics.failure(error, stage: stage) }
            var removed = true
            for url in converted.values {
                do { try temporaryFiles.remove(url) }
                catch { removed = false; diagnostics.failure(error, stage: "cleanup_audio") }
            }
            diagnostics.record(["apple_temporary_audio_removed": String(removed)])
            if let failure = error as? AppleSpeechFailure {
                throw AppleSpeechFailure(stage: failure.stage, summary: failure.summary, configuration: diagnostics.configuration())
            }
            throw diagnostics.wrappedFailure(error, stage: stage)
        }
    }

    private func transcribeRegion(converted: URL, module: SpeechTranscriber, format: AVAudioFormat,
                                  region: LanguageRegion, segmentOffset: Int, cancellation: CancellationFlag,
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
                                                  startSeconds: region.startSeconds, endSeconds: region.endSeconds,
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
                                let item = Segment(id: segmentOffset + segments.count,
                                    startSeconds: min(input.endSeconds, max(input.startSeconds, lo)),
                                    endSeconds: min(input.endSeconds, max(input.startSeconds, hi)),
                                    text: String(result.text.characters), language: region.language)
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
