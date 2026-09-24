import SwiftUI
import AVFoundation
import UIKit
import VoiceBenchCore

@MainActor
final class BenchViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: UUID?
    @Published var busy = false
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var message = "导入模型和苹果中文资源后，即可开始离线对比。"
    @Published var error: String?
    @Published var modelReceipt: ModelReceipt?
    @Published var speech = SpeechCapability(available: false, installed: false, detail: "正在检查…")
    @Published var correctionUnavailable: String? = "正在检查…"
    @Published var lowMemory = false
    @Published var language = "auto"
    @Published var appleFirst = false
    @Published var shareFiles: [URL] = []
    @Published var showShare = false
    @Published var evaluations: [UUID: RunEvaluation] = [:]
    private var store: LocalStore?
    private let sense = SenseVoiceEngine()
    private let apple = AppleSpeechEngine()
    private let corrector = AppleTextCorrector()
    private var task: Task<Void, Never>?
    private var cancellation = CancellationFlag()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var interrupted = false

    var current: Recording? { recordings.first { $0.id == selectedID } }
    var canRun: Bool { current != nil && !busy && !isRecording }
    var bothReady: Bool { modelReceipt != nil && speech.installed && speech.available }

    init() {
        do { store = try LocalStore() } catch { self.error = error.localizedDescription }
        Task {
            do {
                recordings = try await store?.load() ?? []
                selectedID = recordings.first?.id
                await refresh()
            } catch { self.error = error.localizedDescription }
        }
    }

    func refresh() async {
        modelReceipt = await store?.modelReceipt()
        speech = await apple.capability()
        correctionUnavailable = await corrector.availability()
    }

    func importAudio(_ url: URL, removeSourceAfterImport: Bool = false) {
        guard !busy, !isRecording, let store else { return }
        begin("正在导入音频…")
        task = Task {
            defer { finish() }
            do {
                let item = try await store.importAudio(url)
                if removeSourceAfterImport { try? FileManager.default.removeItem(at: url) }
                recordings.insert(item, at: 0); selectedID = item.id
                message = "音频已保存，两套引擎将使用这一份源文件。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func importModels(_ url: URL) {
        guard !busy, !isRecording, let store else { return }
        begin("正在复制并校验模型，可能需要一些时间…")
        task = Task {
            defer { finish() }
            do { modelReceipt = try await store.importModels(url); message = "模型文件已就绪，首次运行将检查能否初始化。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func prepareApple() {
        guard !busy, !isRecording else { return }
        begin("正在准备苹果中文资源…")
        task = Task {
            defer { finish() }
            do {
                try await apple.prepare { [weak self] fraction in
                    await self?.setMessage("正在准备苹果中文资源 \(Int(fraction * 100))%")
                }
                message = "苹果中文资源已就绪。"
            } catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func startRecording() {
        guard !busy, !isRecording else { return }
        player?.stop()
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
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("录音-" + Date().formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: "-") + ".m4a")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: session.sampleRate,
                                              AVNumberOfChannelsKey: 1,
                                              AVEncoderBitRateKey: 96000]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                guard recorder.record() else { throw BenchError("无法开始录音。") }
                self.recorder = recorder; recordingURL = url
                isRecording = true; recordingStartedAt = Date()
                message = "正在录音，停止后可依次运行两套引擎。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop(); recorder = nil
        isRecording = false; recordingStartedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let url = recordingURL { importAudio(url, removeSourceAfterImport: true) }
        recordingURL = nil
    }

    func play() {
        guard canRun, let item = current, let store else { return }
        Task {
            do {
                let url = await store.audioURL(item)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
            } catch { self.error = error.localizedDescription }
        }
    }
    func stopPlayback() { player?.stop() }

    func setReference(_ text: String) { editCurrent { $0.reference = text } }
    func setContext(_ text: String) { editCurrent { $0.context = text } }
    private func editCurrent(_ edit: (inout Recording) -> Void) {
        guard !busy, let index = recordings.firstIndex(where: { $0.id == selectedID }) else { return }
        edit(&recordings[index])
        recordings[index].revision += 1
        evaluations = [:]
        let snapshot = recordings[index]
        Task { do { try await store?.save(snapshot) } catch { self.error = error.localizedDescription } }
    }

    func deleteCurrent() {
        guard canRun, let item = current, let store else { return }
        begin("正在删除录音及关联结果…")
        task = Task {
            defer { finish() }
            do {
                player?.stop()
                try await store.delete(item)
                recordings.removeAll { $0.id == item.id }; selectedID = recordings.first?.id
                message = "已删除。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func run(_ engines: [EngineID]) {
        guard canRun, let recording = current, let store else { return }
        player?.stop()
        begin("开始转写…")
        let flag = cancellation, chosenLanguage = language, lowMemory = lowMemory
        let receipt = modelReceipt
        task = Task {
            defer { finish() }
            let source = await store.audioURL(recording)
            let models = await store.models
            for engine in engines {
                if flag.isCancelled || Task.isCancelled { break }
                var run = Run(engine: engine)
                run.configuration = environment()
                if engine == .senseVoice {
                    run.configuration.merge(receipt?.files.mapKeys { "model_sha256_" + $0 } ?? [:]) { _, new in new }
                    run.configuration.merge(["language": chosenLanguage, "threads": lowMemory ? "1" : "2",
                                             "provider": "cpu", "sample_rate": "16000", "itn": "true",
                                             "sherpa_onnx": "1.13.8", "onnxruntime": "1.28.2"]) { _, new in new }
                } else {
                    run.configuration["requested_locale"] = "zh-CN"
                    run.configuration["offline"] = "true"
                }
                let runID = run.id
                do {
                    try await append(run, recordingID: recording.id)
                    message = "\(engine.title) 正在初始化 / 转写…"
                    let progress: @Sendable (Segment) async -> Void = { [weak self] segment in
                        await self?.received(segment, runID: runID, recordingID: recording.id, flag: flag)
                    }
                    let output: EngineOutput
                    if engine == .senseVoice {
                        guard receipt != nil else { throw BenchError("请先导入完整的 SenseVoice 模型目录。") }
                        output = try await sense.transcribe(source: source, models: models, language: chosenLanguage,
                                                           lowMemory: lowMemory, cancellation: flag, progress: progress)
                    } else {
                        output = try await apple.transcribe(source: source, cancellation: flag, progress: progress)
                    }
                    try flag.check()
                    run.status = .completed; run.preparationMS = output.preparationMS
                    run.transcriptionMS = output.transcriptionMS; run.segments = output.segments; run.rawText = output.text
                    run.configuration.merge(output.configuration) { _, new in new }
                    try await replace(run, recordingID: recording.id)
                } catch {
                    if let partial = findRun(runID, recordingID: recording.id) { run = partial }
                    run.status = flag.isCancelled || Task.isCancelled ? (interrupted ? .interrupted : .cancelled) : .failed
                    run.error = run.status == .interrupted ? "App 进入后台或发生系统中断，未完成结果保留，请在前台重新运行。" : error.localizedDescription
                    do { try await replace(run, recordingID: recording.id) }
                    catch { self.error = "保存运行状态失败：\(error.localizedDescription)" }
                    if flag.isCancelled { break }
                }
            }
            message = flag.isCancelled ? "任务已停止，已完成的结果仍保留。" : "本轮执行结束，请查看每套引擎的状态。"
        }
    }

    func runBoth() { run(appleFirst ? [.apple, .senseVoice] : [.senseVoice, .apple]); appleFirst.toggle() }

    func correct(runID: UUID) {
        guard canRun, let recording = current, let run = recording.runs.first(where: { $0.id == runID }), run.status == .completed else { return }
        begin("正在本地纠错，原始转写保持不变…")
        let flag = cancellation
        task = Task {
            defer { finish() }
            var initial = Correction(); initial.status = "running"
            await updateCorrection(initial, runID: runID, recordingID: recording.id)
            let result = await corrector.correct(original: run.rawText, context: recording.context, cancellation: flag) { [weak self] correction in
                await self?.updateCorrection(correction, runID: runID, recordingID: recording.id)
            }
            await updateCorrection(result, runID: runID, recordingID: recording.id)
            message = "纠错状态：\(result.status)"
        }
    }

    func export() {
        guard canRun, let item = current, let store else { return }
        begin("正在生成报告…")
        task = Task {
            defer { finish() }
            do { shareFiles = try await store.export(item, environment: environment()); showShare = true; message = "报告已生成。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func evaluate() {
        guard canRun, let item = current else { return }
        begin("正在计算字符错误率…")
        task = Task {
            defer { finish() }
            let metrics = await Task.detached(priority: .userInitiated) {
                Report(recording: item, environment: [:]).evaluation
            }.value
            evaluations = Dictionary(uniqueKeysWithValues: metrics.map { ($0.runID, $0) })
            message = "CER 已更新；负的 ΔCER 表示纠错改善。"
        }
    }

    func cancel() { cancellation.cancel(); task?.cancel(); message = "正在结束当前操作；原生推理会在当前片段结束后停止。" }
    func backgrounded() {
        player?.stop()
        if isRecording { stopRecording() }
        else if busy { interrupted = true; cancel() }
    }

    private func begin(_ text: String) {
        cancellation = CancellationFlag(); interrupted = false; busy = true; error = nil; message = text
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private func finish() {
        busy = false; task = nil
        UIApplication.shared.isIdleTimerDisabled = isRecording
    }
    private func setMessage(_ text: String) { message = text }
    private func append(_ run: Run, recordingID: UUID) async throws {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[index].runs.append(run)
        recordings[index].revision += 1
        try await store?.save(recordings[index])
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
    private func updateCorrection(_ correction: Correction, runID: UUID, recordingID: UUID) async {
        guard var run = findRun(runID, recordingID: recordingID) else { return }
        run.correction = correction
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
                "memory_measurement": "not_measured", "execution": "on_device_only"]
    }
}

private extension Dictionary where Key == String, Value == String {
    func mapKeys(_ transform: (String) -> String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
