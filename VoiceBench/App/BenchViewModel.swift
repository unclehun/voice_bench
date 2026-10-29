import SwiftUI
import AVFoundation
import UIKit
import VoiceBenchCore

enum BenchActivity: Equatable { case recognition, correction, resources }

@MainActor
final class BenchViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var isClearingData = false
    @Published var isRecording = false
    @Published var showRecorder = false
    @Published var playingID: UUID?
    @Published var activeRecordingID: UUID?
    @Published var activity: BenchActivity?
    @Published var recordingStartedAt: Date?
    @Published var recordedSeconds: Double = 0
    @Published var message = "导入模型并准备苹果语言资源后，即可自动检测语言、离线对比。"
    @Published var error: String?
    @Published var modelReceipt: ModelReceipt?
    @Published var modelDetail = "正在检查默认模型目录…"
    @Published var languageModelReceipt: ModelReceipt?
    @Published var languageModelDetail = "正在检查 Whisper 默认目录…"
    @Published var qwenModelReceipt: ModelReceipt?
    @Published var qwenModelDetail = "正在检查 Qwen 默认目录…"
    @Published var funASRModelReceipt: ModelReceipt?
    @Published var funASRModelDetail = "正在检查 Fun-ASR 默认目录…"
    @Published var speech = SpeechCapability(available: false, installed: false, detail: "正在检查…")
    @Published var correctionUnavailable: String? = "正在检查…"
    @Published var deepSeekKeyConfigured = false
    @Published var deepSeekKeyStatus = "尚未配置 API Key"
    @Published var shareFiles: [URL] = []
    @Published var showShare = false
    @Published var evaluations: [UUID: RunEvaluation] = [:]
    private var store: LocalStore?
    private let sense = SenseVoiceEngine()
    private let apple = AppleSpeechEngine()
    private let qwen = QwenSpeechEngine()
    private let funASR = FunASRSpeechEngine()
    private let languageDetector = WhisperLanguageDetector()
    private let corrector = AppleTextCorrector()
    private let deepSeekCorrector = DeepSeekTextCorrector()
    private let credentials = DeepSeekCredentialStore()
    private var task: Task<Void, Never>?
    private var cancellation = CancellationFlag()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var playerObserver: PlaybackObserver?
    private var playbackTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var recordingURL: URL?
    private var interrupted = false

    var current: Recording? { recordings.first { $0.id == selectedID } }
    var idle: Bool { !busy && !isRecording && !showShare }
    var canRun: Bool { current != nil && idle }
    var appleReady: Bool { languageModelReceipt != nil && speech.installed && speech.available }
    var bothReady: Bool { modelReceipt != nil && appleReady }
    var comparisonEngines: [EngineID] {
        [.senseVoice, .apple] + (qwenModelReceipt == nil ? [] : [.qwen]) + (funASRModelReceipt == nil ? [] : [.funASR])
    }

    init() {
        do { store = try LocalStore() } catch { self.error = error.localizedDescription }
        refreshDeepSeekKeyStatus()
        Task {
            do {
                recordings = try await store?.load() ?? []
                selectedID = recordings.first?.id
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    func refresh() async {
        refreshDeepSeekKeyStatus()
        do {
            if let receipt = try await store?.importDefaultModelsIfComplete() {
                modelReceipt = receipt
                message = "已从默认目录 SenseVoiceSmall_INT8 载入模型。"
            }
        } catch {
            modelDetail = "默认目录模型校验失败：\(error.localizedDescription)"
        }
        modelReceipt = await store?.modelReceipt()
        if modelReceipt != nil {
            modelDetail = "模型文件已就绪；下次启动无需再次选择目录。"
        } else if modelDetail == "正在检查默认模型目录…" {
            modelDetail = "默认目录为空或尚未传完模型；也可手动选择其他目录。"
        }
        do {
            if let receipt = try await store?.importDefaultLanguageModelsIfComplete() {
                languageModelReceipt = receipt
                message = "已从默认目录 WhisperTiny_INT8 载入语言检测模型。"
            }
        } catch { languageModelDetail = "Whisper 默认目录校验失败：\(error.localizedDescription)" }
        languageModelReceipt = await store?.languageModelReceipt()
        if languageModelReceipt != nil {
            languageModelDetail = "已就绪；Apple 识别前自动检测语言，无需录音前选择。"
        } else if languageModelDetail == "正在检查 Whisper 默认目录…" {
            languageModelDetail = "默认目录为空或尚未传完模型；也可手动选择目录。"
        }
        speech = await apple.capability()
        correctionUnavailable = await corrector.availability()
        do {
            if let receipt = try await store?.importDefaultQwenModelsIfComplete() {
                qwenModelReceipt = receipt
                message = "已从默认目录 Qwen3ASR_0_6B_INT8 载入模型。"
            }
        } catch { qwenModelDetail = "Qwen 默认目录校验失败：\(error.localizedDescription)" }
        qwenModelReceipt = await store?.qwenModelReceipt()
        if qwenModelReceipt != nil {
            qwenModelDetail = "模型已就绪；直接进行本地多语识别，无需选择语言。"
        } else if qwenModelDetail == "正在检查 Qwen 默认目录…" {
            qwenModelDetail = "默认目录为空或尚未传完；也可手动选择完整 Qwen 模型目录。"
        }
        do {
            if let receipt = try await store?.importDefaultFunASRModelsIfComplete() {
                funASRModelReceipt = receipt
                message = "已从默认目录 FunASR_MLT_Nano_INT8 载入模型。"
            }
        } catch { funASRModelDetail = "Fun-ASR 默认目录校验失败：\(error.localizedDescription)" }
        funASRModelReceipt = await store?.funASRModelReceipt()
        if funASRModelReceipt != nil {
            funASRModelDetail = "模型已就绪；直接进行本地多语识别，无需选择语言。"
        } else if funASRModelDetail == "正在检查 Fun-ASR 默认目录…" {
            funASRModelDetail = "默认目录为空或尚未传完；也可手动选择完整 Fun-ASR 模型目录。"
        }
    }

    private func refreshDeepSeekKeyStatus() {
        do {
            deepSeekKeyConfigured = try credentials.read() != nil
            deepSeekKeyStatus = deepSeekKeyConfigured ? "API Key 已保存在 App 数据目录；重启或覆盖更新后自动读取" : "尚未配置 API Key；仅运行 Apple 本地纠错"
        } catch {
            deepSeekKeyConfigured = false
            deepSeekKeyStatus = error.localizedDescription
        }
    }

    @discardableResult
    func saveDeepSeekAPIKey(_ value: String) -> Bool {
        guard idle else { return false }
        do {
            try credentials.save(value)
            refreshDeepSeekKeyStatus()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func removeDeepSeekAPIKey() {
        guard idle else { return }
        defer { refreshDeepSeekKeyStatus() }
        do { try credentials.remove() }
        catch { self.error = error.localizedDescription }
    }

    func importAudio(_ url: URL, removeSourceAfterImport: Bool = false) {
        guard !busy, !isRecording, let store else { return }
        begin("正在导入音频…")
        task = Task {
            defer {
                if removeSourceAfterImport { try? AppTemporaryFiles.live.remove(url) }
                finish()
            }
            do {
                let existingNames = Set(recordings.map(\.name))
                var nextNumber = 1
                while existingNames.contains("录音 \(nextNumber)") { nextNumber += 1 }
                let item = try await store.importAudio(url, displayName: removeSourceAfterImport ? "录音 \(nextNumber)" : nil)
                recordings.insert(item, at: 0); selectedID = item.id
                showRecorder = false
                message = "音频已保存，各套引擎将使用这一份源文件。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importModels(_ url: URL) {
        guard !busy, !isRecording, let store else { return }
        begin("正在复制并校验模型，可能需要一些时间…")
        task = Task {
            defer { finish() }
            do {
                modelReceipt = try await store.importModels(url)
                modelDetail = "已从手工选择的目录载入；模型已保存到 App 内部。"
                message = "模型文件已就绪，首次运行将检查能否初始化。"
            }
            catch { self.error = error.localizedDescription }
        }
    }

    func importDefaultModels() {
        guard !busy, !isRecording, let store else { return }
        begin("正在从默认目录载入并校验模型…")
        task = Task {
            defer { finish() }
            do {
                modelReceipt = try await store.importDefaultModels()
                modelDetail = "已从默认目录 SenseVoiceSmall_INT8 载入模型。"
                message = "默认目录模型已就绪，首次运行将检查能否初始化。"
            } catch {
                self.error = error.localizedDescription
                modelDetail = "默认目录尚不可用；可补齐文件或手动选择目录。"
            }
        }
    }

    func prepareApple() {
        guard !busy, !isRecording else { return }
        begin("正在准备苹果语言资源…", activity: .resources)
        let detected = current?.runs.last(where: { $0.engine == .apple })?.languageDetection?.languages ?? []
        let languages = Array(Set(["zh", "en"] + detected)).sorted()
        task = Task {
            defer { finish() }
            do {
                try await apple.prepare(languages: languages) { [weak self] fraction in
                    await self?.setMessage("正在准备苹果语言资源 \(Int(fraction * 100))%")
                }
                message = "苹果语言资源已就绪：\(languages.map(LanguageRouting.name).joined(separator: "、"))。"
            } catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func importLanguageModels(_ source: URL? = nil) {
        guard !busy, !isRecording, let store else { return }
        begin("正在复制并校验 Whisper Tiny 语言模型…")
        task = Task {
            defer { finish() }
            do {
                if let source { languageModelReceipt = try await store.importLanguageModels(source) }
                else { languageModelReceipt = try await store.importDefaultLanguageModels() }
                languageModelDetail = "已就绪；语言检测模型已保存到 App 内部。"
                message = "Whisper Tiny 已就绪。录音后点击运行即可自动检测语言。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importQwenModels(_ source: URL? = nil) {
        guard idle, let store else { return }
        begin("正在复制并校验 Qwen3-ASR 模型（约 1 GB）…")
        task = Task {
            defer { finish() }
            do {
                if let source { qwenModelReceipt = try await store.importQwenModels(source) }
                else { qwenModelReceipt = try await store.importDefaultQwenModels() }
                qwenModelDetail = "已保存到 App 内部；下次启动无需再次选择目录。"
                message = "Qwen3-ASR 已就绪，可进行三套引擎对比或在详情中单独运行。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importFunASRModels(_ source: URL? = nil) {
        guard idle, let store else { return }
        begin("正在复制并校验 Fun-ASR-MLT-Nano 模型（约 1 GB）…")
        task = Task {
            defer { finish() }
            do {
                if let source { funASRModelReceipt = try await store.importFunASRModels(source) }
                else { funASRModelReceipt = try await store.importDefaultFunASRModels() }
                funASRModelDetail = "已保存到 App 内部；下次启动无需再次选择目录。"
                message = "Fun-ASR-MLT-Nano 已就绪，可进行多套引擎对比或在详情中单独运行。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func openRecorder() {
        guard idle else { return }
        stopPlayback(); recordedSeconds = 0; error = nil; showRecorder = true
    }

    func startRecording() {
        guard !busy, !isRecording else { return }
        stopPlayback()
        begin("正在准备录音…")
        task = Task {
            defer { finish() }
            let granted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { error = "麦克风权限未开启，请在系统设置中允许访问。"; return }
            guard !Task.isCancelled else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                try session.setActive(true)
                let url = try AppTemporaryFiles.live.file(extension: "m4a", prefix: "录音-")
                var started = false
                defer { if !started { try? AppTemporaryFiles.live.remove(url) } }
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: session.sampleRate,
                                              AVNumberOfChannelsKey: 1,
                                              AVEncoderBitRateKey: 96000]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                guard recorder.record() else { throw BenchError("无法开始录音。") }
                self.recorder = recorder; recordingURL = url
                started = true
                isRecording = true; recordedSeconds = 0; recordingStartedAt = Date()
                message = "正在录音，停止后可依次运行识别引擎。"
            } catch {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.error = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordedSeconds = recorder?.currentTime ?? 0
        recorder?.stop(); recorder = nil
        isRecording = false; recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = recordingURL { importAudio(url, removeSourceAfterImport: true) }
        recordingURL = nil
    }

    func play(recordingID: UUID) {
        guard idle, let item = recordings.first(where: { $0.id == recordingID }), let store else { return }
        if playingID == item.id { stopPlayback(); return }
        stopPlayback()
        let generation = playbackGeneration
        selectedID = item.id
        playbackTask = Task {
            do {
                let url = await store.audioURL(item)
                try Task.checkCancellation()
                guard idle, recordings.contains(where: { $0.id == item.id }) else { return }
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                let audioPlayer = try AVAudioPlayer(contentsOf: url)
                let observer = PlaybackObserver { [weak self] in
                    Task { @MainActor in if self?.playbackGeneration == generation { self?.stopPlayback() } }
                }
                audioPlayer.delegate = observer
                guard audioPlayer.play() else { throw BenchError("无法播放该录音。") }
                player = audioPlayer; playerObserver = observer; playingID = item.id
            } catch is CancellationError { }
            catch { stopPlayback(); self.error = error.localizedDescription }
        }
    }
    func stopPlayback() {
        playbackGeneration = UUID()
        playbackTask?.cancel(); playbackTask = nil
        player?.stop(); player = nil; playerObserver = nil; playingID = nil
        if !isRecording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func setReference(_ text: String, recordingID: UUID) { edit(recordingID) { $0.reference = text } }
    func setContext(_ text: String, recordingID: UUID) { edit(recordingID) { $0.context = text } }
    private func edit(_ recordingID: UUID, _ edit: (inout Recording) -> Void) {
        guard idle, let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        edit(&recordings[index])
        recordings[index].revision += 1
        evaluations = [:]
        let snapshot = recordings[index]
        Task { do { try await store?.save(snapshot) } catch { self.error = error.localizedDescription } }
    }

    func delete(recordingID: UUID) {
        guard idle, let item = recordings.first(where: { $0.id == recordingID }), let store else { return }
        stopPlayback()
        begin("正在删除录音及关联结果…", recordingID: recordingID)
        task = Task {
            defer { finish() }
            do {
                try await store.delete(item)
                recordings.removeAll { $0.id == item.id }
                if selectedID == item.id { selectedID = recordings.first?.id }
                for run in item.runs { evaluations[run.id] = nil }
                message = "已删除。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func run(_ engines: [EngineID], recordingID: UUID) {
        guard idle, !engines.isEmpty, let recording = recordings.first(where: { $0.id == recordingID }), let store else { return }
        stopPlayback(); selectedID = recordingID
        begin("开始转写…", recordingID: recordingID, activity: .recognition)
        let flag = cancellation
        let receipt = modelReceipt
        let languageReceipt = languageModelReceipt
        let qwenReceipt = qwenModelReceipt
        let funASRReceipt = funASRModelReceipt
        task = Task {
            defer { finish() }
            let source = await store.audioURL(recording)
            let models = await store.models
            let languageModels = await store.languageModels
            let qwenModels = await store.qwenModels
            let funASRModels = await store.funASRModels
            let workFiles = await store.workFiles(recordingID: recordingID)
            let temporaryFiles = await store.temporaryFiles
            defer {
                do { try temporaryFiles.remove(workFiles.root) }
                catch { self.error = "本次识别临时文件清理未完成：\(error.localizedDescription)；删除该录音时会再次清理。" }
            }
            let batchID = UUID()
            let queued = engines.map { engine -> Run in
                var run = Run(engine: engine)
                run.batchID = batchID
                run.configuration = environment()
                run.configuration["execution_state"] = "queued"
                return run
            }
            do { try await append(queued, recordingID: recordingID) }
            catch { self.error = "保存识别任务失败：\(error.localizedDescription)"; return }
            for pending in queued {
                if flag.isCancelled || Task.isCancelled { break }
                var run = pending
                let engine = run.engine
                run.configuration["execution_state"] = "executing"
                if engine == .senseVoice {
                    run.configuration.merge(receipt?.files.mapKeys { "model_sha256_" + $0 } ?? [:]) { _, new in new }
                    run.configuration.merge(["language": "auto", "threads": "2",
                                             "provider": "cpu", "sample_rate": "16000", "itn": "true",
                                             "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2"]) { _, new in new }
                } else if engine == .qwen {
                    run.configuration.merge(qwenReceipt?.files.mapKeys { "qwen_model_sha256_" + $0 } ?? [:]) { _, new in new }
                    run.configuration.merge(["qwen_language_strategy": "model_native_auto", "offline": "true",
                        "provider": "cpu", "threads": "2", "sample_rate": "16000",
                        "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2"]) { _, new in new }
                } else if engine == .funASR {
                    run.configuration.merge(funASRReceipt?.files.mapKeys { "funasr_mlt_model_sha256_" + $0 } ?? [:]) { _, new in new }
                    run.configuration.merge(["funasr_mlt_language_strategy": "model_native_auto", "offline": "true",
                        "provider": "cpu", "threads": "2", "sample_rate": "16000",
                        "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2"]) { _, new in new }
                } else {
                    run.configuration["requested_locale"] = "automatic_from_whisper_tiny"
                    run.configuration["offline"] = "true"
                    run.configuration.merge(languageReceipt?.files.mapKeys { "lid_model_sha256_" + $0 } ?? [:]) { _, new in new }
                    run.configuration.merge(["lid_model": LanguageDetection.modelVersion, "lid_provider": "cpu",
                        "lid_threads": "2", "lid_sample_rate": "16000", "lid_window_seconds": "5",
                        "lid_vad_max_seconds": "25", "lid_vad_min_silence": "0.6",
                        "lid_vad_min_speech": "0", "lid_tail_merge_seconds": "1", "lid_edge_padding_ms": "200",
                        "lid_strategy": "vad-window-vote-v1", "lid_confidence": "not_exposed_by_api",
                        "lid_short_window_warning_seconds": "1"]) { _, new in new }
                }
                let runID = run.id
                do {
                    try await replace(run, recordingID: recording.id)
                    message = "\(engine.title) 正在初始化 / 转写…"
                    let progress: @Sendable (Segment) async -> Void = { [weak self] segment in
                        await self?.received(segment, runID: runID, recordingID: recording.id, flag: flag)
                    }
                    let output: EngineOutput
                    if engine == .senseVoice {
                        guard receipt != nil else { throw BenchError("请先导入完整的 SenseVoice 模型目录。") }
                        output = try await sense.transcribe(source: source, models: models, cancellation: flag,
                                                           temporaryFiles: workFiles, progress: progress)
                    } else if engine == .qwen {
                        guard qwenReceipt != nil else { throw BenchError("请先导入完整的 Qwen3ASR_0_6B_INT8 模型目录。") }
                        output = try await qwen.transcribe(source: source, models: qwenModels, runID: runID,
                            cancellation: flag, temporaryFiles: workFiles, progress: progress)
                    } else if engine == .funASR {
                        guard funASRReceipt != nil else { throw BenchError("请先导入完整的 FunASR_MLT_Nano_INT8 模型目录。") }
                        output = try await funASR.transcribe(source: source, models: funASRModels, runID: runID,
                            cancellation: flag, temporaryFiles: workFiles, progress: progress)
                    } else {
                        guard languageReceipt != nil else { throw BenchError("请先导入 WhisperTiny_INT8 语言检测模型。") }
                        message = "Whisper Tiny 正在检测整段录音的语言…"
                        let plan = try await languageDetector.detect(source: source, models: languageModels,
                            runID: runID, cancellation: flag, temporaryFiles: workFiles) { [weak self] count in
                                await self?.setMessage("Whisper Tiny 已检测 \(count) 个语言窗口…")
                            }
                        run.languageDetection = plan
                        run.preparationMS = plan.preparationMS
                        run.transcriptionMS = plan.detectionMS
                        // Preserve the plan even when Apple lacks a detected language's resources.
                        try await replace(run, recordingID: recording.id)
                        message = "Apple 正在按检测到的语言转写…"
                        var appleOutput = try await apple.transcribe(source: source, plan: plan, runID: runID,
                                                                     cancellation: flag, temporaryFiles: workFiles, progress: progress)
                        appleOutput.preparationMS += plan.preparationMS
                        appleOutput.transcriptionMS += plan.detectionMS
                        output = appleOutput
                    }
                    try flag.check()
                    run.configuration["execution_state"] = "finished"
                    run.status = .completed; run.preparationMS = output.preparationMS
                    run.transcriptionMS = output.transcriptionMS; run.segments = output.segments; run.rawText = output.text
                    run.configuration.merge(output.configuration) { _, new in new }
                    try await replace(run, recordingID: recording.id)
                } catch {
                    if let partial = findRun(runID, recordingID: recording.id) { run = partial }
                    if let failure = error as? AppleSpeechFailure {
                        run.configuration.merge(failure.configuration) { _, new in new }
                    }
                    if let failure = error as? LanguageIDFailure {
                        run.configuration.merge(failure.configuration) { _, new in new }
                    }
                    if let failure = error as? QwenSpeechFailure {
                        run.configuration.merge(failure.configuration) { _, new in new }
                    }
                    if let failure = error as? FunASRSpeechFailure {
                        run.configuration.merge(failure.configuration) { _, new in new }
                    }
                    run.configuration["execution_state"] = "finished"
                    run.status = flag.isCancelled || Task.isCancelled ? (interrupted ? .interrupted : .cancelled) : .failed
                    run.error = run.status == .interrupted ? "App 进入后台或发生系统中断，未完成结果保留，请在前台重新运行。" : error.localizedDescription
                    do { try await replace(run, recordingID: recording.id) }
                    catch { self.error = "保存运行状态失败：\(error.localizedDescription)" }
                    if flag.isCancelled { break }
                }
            }
            // All rows are queued up front. Cancelled comparisons must close untouched rows too.
            for pending in queued {
                if var unfinished = findRun(pending.id, recordingID: recordingID), unfinished.status == .running {
                    unfinished.status = interrupted ? .interrupted : .cancelled
                    unfinished.configuration["execution_state"] = "finished"
                    unfinished.error = "本轮识别已停止。"
                    do { try await replace(unfinished, recordingID: recordingID) }
                    catch { self.error = "保存停止状态失败：\(error.localizedDescription)" }
                }
            }
            message = flag.isCancelled ? "任务已停止，已完成的结果仍保留。" : "本轮执行结束，请查看每套引擎的状态。"
        }
    }

    func runBoth(recordingID: UUID) {
        guard idle else { return }
        guard bothReady else { error = "请先到设置完成 SenseVoice、Whisper 和苹果语言资源配置。"; return }
        run([.senseVoice, .apple], recordingID: recordingID)
    }

    func runComparison(recordingID: UUID) {
        guard qwenModelReceipt != nil || funASRModelReceipt != nil else { runBoth(recordingID: recordingID); return }
        guard idle else { return }
        guard bothReady else { error = "请先到设置完成 SenseVoice、Whisper 和苹果语言资源配置；Qwen 和 Fun-ASR 也可在详情中单独运行。"; return }
        run(comparisonEngines, recordingID: recordingID)
    }

    func correctLatest(recordingID: UUID) {
        guard let recording = recordings.first(where: { $0.id == recordingID }) else { return }
        correct(recording.correctionCandidates, recording: recording)
    }

    func correct(runID: UUID, recordingID: UUID) {
        guard let recording = recordings.first(where: { $0.id == recordingID }),
              let run = recording.runs.first(where: { $0.id == runID }), run.status == .completed else { return }
        correct([run], recording: recording)
    }

    private func correct(_ runs: [Run], recording: Recording) {
        guard idle, !runs.isEmpty else { return }
        stopPlayback(); selectedID = recording.id
        begin("正在并行启动 Apple / DeepSeek 纠错…", recordingID: recording.id, activity: .correction)
        let flag = cancellation
        task = Task {
            defer { finish() }
            let key: String?
            let credentialFailure: String?
            do { key = try credentials.read(); credentialFailure = nil }
            catch { key = nil; credentialFailure = error.localizedDescription }
            for run in runs {
                if flag.isCancelled || Task.isCancelled { break }
                for provider in CorrectionProvider.allCases {
                    var initial = provider == .apple ? Correction() : DeepSeekTextCorrector.initialCorrection(context: recording.context)
                    initial.context = recording.context; initial.status = "running"
                    await updateCorrection(initial, provider: provider, runID: run.id, recordingID: recording.id)
                }
                message = "\(run.engine.title)：Apple 本地与 DeepSeek 公网纠错同时运行…"
                // Structured children inherit cancellation; each persists independently as soon as it finishes.
                async let local: Void = correctWithApple(run, recording: recording, flag: flag)
                async let remote: Void = correctWithDeepSeek(run, recording: recording, apiKey: key,
                                                            credentialFailure: credentialFailure, flag: flag)
                _ = await (local, remote)
            }
            message = flag.isCancelled ? "纠错已停止，已完成的模型结果仍保留。" : "纠错已结束，Apple 与 DeepSeek 的状态和结果已分别展示。"
        }
    }

    private func correctWithApple(_ run: Run, recording: Recording, flag: CancellationFlag) async {
        let result = await corrector.correct(original: run.rawText, context: recording.context, cancellation: flag) { [weak self] correction in
            await self?.updateCorrection(correction, provider: .apple, runID: run.id, recordingID: recording.id)
        }
        await updateCorrection(result, provider: .apple, runID: run.id, recordingID: recording.id)
    }

    private func correctWithDeepSeek(_ run: Run, recording: Recording, apiKey: String?, credentialFailure: String?,
                                     flag: CancellationFlag) async {
        let result: Correction
        if let credentialFailure {
            var failure = DeepSeekTextCorrector.initialCorrection(context: recording.context)
            failure.status = "failed"; failure.error = credentialFailure
            result = failure
        } else {
            result = await deepSeekCorrector.correct(original: run.rawText, context: recording.context, apiKey: apiKey, cancellation: flag) { [weak self] correction in
                await self?.updateCorrection(correction, provider: .deepSeek, runID: run.id, recordingID: recording.id)
            }
        }
        await updateCorrection(result, provider: .deepSeek, runID: run.id, recordingID: recording.id)
    }

    func export(recordingID: UUID) {
        guard idle, let item = recordings.first(where: { $0.id == recordingID }), let store else { return }
        selectedID = recordingID
        begin("正在生成报告…", recordingID: recordingID)
        task = Task {
            defer { finish() }
            do { shareFiles = try await store.export(item, environment: environment()); showShare = true; message = "报告已生成。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func finishSharing() {
        let files = shareFiles
        shareFiles = []
        Task {
            do { try await store?.removeExport(files) }
            catch { self.error = "清理临时报告失败：\(error.localizedDescription)。下次启动会再次清理。" }
        }
    }

    func clearAllData() {
        guard !busy, !isRecording, !showShare, let store else { return }
        stopPlayback(); player = nil
        begin("正在清除本机数据与模型…")
        isClearingData = true
        task = Task {
            defer { isClearingData = false; refreshDeepSeekKeyStatus(); finish() }
            var keyRemovalError: String?
            do { try credentials.remove() }
            catch { keyRemovalError = error.localizedDescription }
            refreshDeepSeekKeyStatus()
            do {
                try await store.removeAllData()
                recordings = []; selectedID = nil; evaluations = [:]
                shareFiles = []; modelReceipt = nil; languageModelReceipt = nil; qwenModelReceipt = nil; funASRModelReceipt = nil; recordingURL = nil
                modelDetail = "默认目录已清空；可重新传入 SenseVoiceSmall_INT8。"
                languageModelDetail = "默认目录已清空；可重新传入 WhisperTiny_INT8。"
                qwenModelDetail = "默认目录已清空；可重新传入 Qwen3ASR_0_6B_INT8。"
                funASRModelDetail = "默认目录已清空；可重新传入 FunASR_MLT_Nano_INT8。"
                await apple.releaseReservations()
                await refresh()
                message = "本机数据和 API Key 配置已清除，苹果语音资源预留已释放。共享系统模型由 iOS 管理。"
            } catch {
                // Do not turn a failed reload into an apparently successful empty recording list.
                if let remaining = try? await store.load() {
                    recordings = remaining
                    selectedID = recordings.first?.id
                }
                modelReceipt = await store.modelReceipt()
                languageModelReceipt = await store.languageModelReceipt()
                qwenModelReceipt = await store.qwenModelReceipt()
                funASRModelReceipt = await store.funASRModelReceipt()
                if modelReceipt == nil { modelDetail = "模型已清除或清理未完成，请检查后重新导入。" }
                if languageModelReceipt == nil { languageModelDetail = "模型已清除或清理未完成，请检查后重新导入。" }
                if qwenModelReceipt == nil { qwenModelDetail = "模型已清除或清理未完成，请检查后重新导入。" }
                if funASRModelReceipt == nil { funASRModelDetail = "模型已清除或清理未完成，请检查后重新导入。" }
                self.error = (["清理未全部完成：\(error.localizedDescription)。可重试。", keyRemovalError].compactMap { $0 }).joined(separator: " ")
            }
        }
    }

    func evaluate(recordingID: UUID) {
        guard idle, let item = recordings.first(where: { $0.id == recordingID }) else { return }
        begin("正在计算字符错误率…", recordingID: recordingID)
        task = Task {
            defer { finish() }
            let metrics = await Task.detached(priority: .userInitiated) {
                Report(recording: item, environment: [:]).evaluation
            }.value
            evaluations = Dictionary(uniqueKeysWithValues: metrics.map { ($0.runID, $0) })
            message = "CER 已更新；负的 ΔCER 表示纠错改善。"
        }
    }

    func cancel() {
        guard !isClearingData else { return }
        cancellation.cancel(); task?.cancel(); message = "正在结束当前操作；原生推理会在当前片段结束后停止。"
    }
    func backgrounded() {
        stopPlayback()
        if isRecording { stopRecording() }
        else if busy { interrupted = true; cancel() }
    }

    private func begin(_ text: String, recordingID: UUID? = nil, activity: BenchActivity? = nil) {
        activeRecordingID = recordingID; self.activity = activity
        cancellation = CancellationFlag(); interrupted = false; busy = true; error = nil; message = text
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func finish() {
        busy = false; task = nil; activeRecordingID = nil; activity = nil
        UIApplication.shared.isIdleTimerDisabled = isRecording
    }
    private func setMessage(_ text: String) { message = text }
    private func append(_ runs: [Run], recordingID: UUID) async throws {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        var snapshot = recordings[index]
        snapshot.runs.append(contentsOf: runs)
        snapshot.revision += 1
        try await store?.save(snapshot)
        recordings[index] = snapshot
    }
    private func replace(_ run: Run, recordingID: UUID) async throws {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }),
              let runIndex = recordings[index].runs.firstIndex(where: { $0.id == run.id }) else { return }
        recordings[index].runs[runIndex] = run
        recordings[index].revision += 1
        evaluations[run.id] = nil
        try await store?.save(recordings[index])
    }
    private func findRun(_ id: UUID, recordingID: UUID) -> Run? {
        recordings.first { $0.id == recordingID }?.runs.first { $0.id == id }
    }
    private func received(_ segment: Segment, runID: UUID, recordingID: UUID, flag: CancellationFlag) async {
        guard var run = findRun(runID, recordingID: recordingID) else { return }
        run.segments.append(segment); run.rawText = run.segments.map(\.text).joined(separator: "\n")
        do { try await replace(run, recordingID: recordingID) }
        catch { self.error = "保存片段失败：\(error.localizedDescription)"; flag.cancel() }
        message = "\(run.engine.title) 已完成 \(run.segments.count) 个片段"
    }
    private func updateCorrection(_ correction: Correction, provider: CorrectionProvider, runID: UUID, recordingID: UUID) async {
        guard var run = findRun(runID, recordingID: recordingID) else { return }
        run.setCorrection(correction, for: provider)
        if interrupted && run.correction(for: provider).status == "cancelled" {
            var value = run.correction(for: provider)
            value.status = "interrupted"; value.error = "App 进入后台或发生系统中断，纠错未完成。"
            run.setCorrection(value, for: provider)
        }
        do { try await replace(run, recordingID: recordingID) }
        catch { self.error = "保存纠错失败：\(error.localizedDescription)"; cancellation.cancel() }
    }

    private func environment() -> [String: String] {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        return ["device": machine, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "thermal_state": String(ProcessInfo.processInfo.thermalState.rawValue),
                "low_power_mode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
                "memory_measurement": "not_measured", "execution": "asr_on_device; optional_deepseek_correction_over_https"]
    }
}

private extension Dictionary where Key == String, Value == String {
    func mapKeys(_ transform: (String) -> String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

private final class PlaybackObserver: NSObject, AVAudioPlayerDelegate {
    let finished: @Sendable () -> Void
    init(finished: @escaping @Sendable () -> Void) { self.finished = finished }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { finished() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { finished() }
}
