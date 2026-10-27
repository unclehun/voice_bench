import Foundation
import AVFoundation
import VoiceBenchCore

struct ModelReceipt: Codable, Sendable {
    var version: String
    var files: [String: String]
    var importedAt: Date
}

actor LocalStore {
    static let requiredModels = ["model.int8.onnx", "tokens.txt", "silero_vad.onnx"]
    static let defaultModelDirectoryName = "SenseVoiceSmall_INT8"
    static let requiredLanguageModels = ["tiny-encoder.int8.onnx", "tiny-decoder.int8.onnx", "silero_vad.onnx"]
    static let defaultLanguageModelDirectoryName = "WhisperTiny_INT8"
    let root: URL
    let models: URL
    let languageModels: URL
    let defaultLanguageModelDirectory: URL
    let audio: URL
    /// This is `Documents/SenseVoiceSmall_INT8`, visible in Files as
    /// `On My iPhone > 语音对比 (or VoiceBench) > SenseVoiceSmall_INT8`.
    let defaultModelDirectory: URL
    let temporaryFiles: AppTemporaryFiles
    private let records: URL
    private var savedRevisions: [UUID: Int] = [:]
    private var deletedRecordings = Set<UUID>()
    private let modelManifestURL: URL?
    private let languageModelManifestURL: URL?
    init(baseURL: URL? = nil, modelManifestURL: URL? = nil, languageModelManifestURL: URL? = nil, temporaryFiles: AppTemporaryFiles? = nil) throws {
        let manager = FileManager.default
        self.modelManifestURL = modelManifestURL ?? Bundle.main.url(forResource: "model-manifest", withExtension: "json")
        self.languageModelManifestURL = languageModelManifestURL ?? Bundle.main.url(forResource: "language-model-manifest", withExtension: "json")
        if let baseURL {
            root = baseURL
            defaultModelDirectory = baseURL.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(Self.defaultModelDirectoryName, isDirectory: true)
        } else {
            root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("VoiceBench", isDirectory: true)
            defaultModelDirectory = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
                .appendingPathComponent(Self.defaultModelDirectoryName, isDirectory: true)
        }
        defaultLanguageModelDirectory = defaultModelDirectory.deletingLastPathComponent()
            .appendingPathComponent(Self.defaultLanguageModelDirectoryName, isDirectory: true)
        languageModels = root.appendingPathComponent("LanguageIDModels", isDirectory: true)
        models = root.appendingPathComponent("Models", isDirectory: true)
        audio = root.appendingPathComponent("Audio", isDirectory: true)
        records = root.appendingPathComponent("Records", isDirectory: true)
        self.temporaryFiles = temporaryFiles ?? baseURL.map { AppTemporaryFiles(root: $0.appendingPathComponent("Temporary")) } ?? .live
        try Self.prepareDirectories(root: root)
        for var sourceURL in [defaultModelDirectory, defaultLanguageModelDirectory] {
            try manager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            var sourceValues = URLResourceValues(); sourceValues.isExcludedFromBackup = true
            try sourceURL.setResourceValues(sourceValues)
        }
        try self.temporaryFiles.reset()
        #if os(iOS)
        if baseURL == nil { try AppTemporaryFiles.removeLegacyFiles(in: manager.temporaryDirectory) }
        #endif
        // A process kill bypasses defer. Remove abandoned model imports on the next launch.
        for url in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name.hasPrefix("Import-"), UUID(uuidString: String(name.dropFirst(7))) != nil { try manager.removeItem(at: url) }
        }
    }
    private static func prepareDirectories(root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var dataURL = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        // This demo deliberately does not put recordings/results/models into future device backups.
        try dataURL.setResourceValues(values)
        for name in ["Models", "LanguageIDModels", "Audio", "Records"] {
            var url = root.appendingPathComponent(name, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try url.setResourceValues(values)
        }
    }
    func load() throws -> [Recording] {
        let urls = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let recordings = try urls.map { url in
            var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
            recording.recoverInterruptedRuns()
            try save(recording)
            return recording
        }.sorted { $0.createdAt > $1.createdAt }
        // Only after every metadata file decoded successfully: remove copies left by interrupted imports.
        let referenced = Set(recordings.map(\.fileName))
        for url in try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil) {
            if !referenced.contains(url.lastPathComponent) { try FileManager.default.removeItem(at: url) }
        }
        return recordings
    }
    func save(_ recording: Recording) throws {
        guard !deletedRecordings.contains(recording.id) else { return }
        guard recording.revision >= savedRevisions[recording.id, default: -1] else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: records.appendingPathComponent(recording.id.uuidString + ".json"), options: .atomic)
        savedRevisions[recording.id] = recording.revision
    }
    func audioURL(_ recording: Recording) -> URL { audio.appendingPathComponent(recording.fileName) }
    func workFiles(recordingID: UUID) -> AppTemporaryFiles { temporaryFiles.workspace(recordingID: recordingID) }
    func importAudio(_ source: URL, displayName: String? = nil) throws -> Recording {
        let ext = source.pathExtension.lowercased()
        guard ["m4a", "wav", "caf"].contains(ext) else { throw BenchError("请选择 M4A 或 WAV 音频。") }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let name = UUID().uuidString + "." + ext
        let destination = audio.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let file = try AVAudioFile(forReading: destination)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw BenchError("录音为空。") }
            let item = Recording(name: displayName ?? source.deletingPathExtension().lastPathComponent, fileName: name,
                                 sha256: try AudioFiles.hash(destination), duration: duration,
                                 sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
            try save(item)
            return item
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func delete(_ recording: Recording) throws {
        // UI serializes deletion with inference. Remove only this recording's working files,
        // including a report that was generated before the share sheet was dismissed.
        try temporaryFiles.remove(workFiles(recordingID: recording.id).root)
        // Remove metadata only after the audio deletion succeeds (if the audio still exists).
        let url = audioURL(recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let metadata = records.appendingPathComponent(recording.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        deletedRecordings.insert(recording.id)
    }
    func modelReceipt() -> ModelReceipt? { receipt(at: models, required: Self.requiredModels) }
    func languageModelReceipt() -> ModelReceipt? { receipt(at: languageModels, required: Self.requiredLanguageModels) }
    private func receipt(at models: URL, required: [String]) -> ModelReceipt? {
        guard let data = try? Data(contentsOf: models.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(ModelReceipt.self, from: data),
              required.allSatisfy({ FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }) else { return nil }
        return receipt
    }
    /// Imports the fixed Files-visible folder once, only when no internal model is installed yet.
    /// An empty or partially copied folder is treated as not ready, so launch never fails mid-transfer.
    func importDefaultModelsIfComplete() throws -> ModelReceipt? {
        guard modelReceipt() == nil, hasCompleteModelSet(at: defaultModelDirectory) else { return nil }
        return try importModels(defaultModelDirectory)
    }
    /// User-triggered reload. Unlike the launch path, report incomplete/corrupt default folders clearly.
    func importDefaultModels() throws -> ModelReceipt {
        let missing = Self.requiredModels.filter {
            !FileManager.default.fileExists(atPath: defaultModelDirectory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw BenchError("默认目录 SenseVoiceSmall_INT8 缺少：\(missing.joined(separator: "、"))")
        }
        return try importModels(defaultModelDirectory)
    }
    private func hasCompleteModelSet(at directory: URL, required: [String] = LocalStore.requiredModels) -> Bool {
        return required.allSatisfy { name in
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }
    func importDefaultLanguageModelsIfComplete() throws -> ModelReceipt? {
        guard languageModelReceipt() == nil,
              hasCompleteModelSet(at: defaultLanguageModelDirectory, required: Self.requiredLanguageModels) else { return nil }
        return try importLanguageModels(defaultLanguageModelDirectory)
    }
    func importDefaultLanguageModels() throws -> ModelReceipt {
        let missing = Self.requiredLanguageModels.filter {
            !FileManager.default.fileExists(atPath: defaultLanguageModelDirectory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else { throw BenchError("默认目录 WhisperTiny_INT8 缺少：\(missing.joined(separator: "、"))") }
        return try importLanguageModels(defaultLanguageModelDirectory)
    }
    func importLanguageModels(_ source: URL) throws -> ModelReceipt {
        try importModelSet(source, required: Self.requiredLanguageModels, destination: languageModels,
                           manifestURL: languageModelManifestURL, version: LanguageDetection.modelVersion)
    }
    func importModels(_ source: URL) throws -> ModelReceipt {
        try importModelSet(source, required: Self.requiredModels, destination: models,
                           manifestURL: modelManifestURL, version: "sense-voice-int8-2024-07-17")
    }
    private func importModelSet(_ source: URL, required: [String], destination: URL,
                                manifestURL: URL?, version: String) throws -> ModelReceipt {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let staging = root.appendingPathComponent("Import-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var hashes: [String: String] = [:]
        for name in required {
            let input = source.appendingPathComponent(name)
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw BenchError("模型文件缺失或为空：\(name)") }
            let output = staging.appendingPathComponent(name)
            try manager.copyItem(at: input, to: output)
            hashes[name] = try AudioFiles.hash(output)
        }
        guard let bundled = manifestURL else {
            throw BenchError("App 缺少模型校验清单，请重新构建。")
        }
        let known = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: bundled))
        guard required.allSatisfy({ known[$0] == hashes[$0] }) else {
            throw BenchError("模型内容与此 Demo 指定版本不一致，请使用配套模型准备脚本。")
        }
        // If the preparation script supplied a manifest, reject changed/corrupt transfers.
        let manifest = source.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: manifest.path) {
            let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            guard required.allSatisfy({ expected[$0] == hashes[$0] }) else { throw BenchError("模型 SHA-256 校验失败，请重新传输模型目录。") }
        }
        for name in ["LICENSE", "MODEL_LICENSE", "VAD_LICENSE"] where manager.fileExists(atPath: source.appendingPathComponent(name).path) {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        let receipt = ModelReceipt(version: version, files: hashes, importedAt: Date())
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
        // Atomic directory swap keeps the old model intact if validation/copy fails.
        _ = try manager.replaceItemAt(destination, withItemAt: staging)
        var url = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return receipt
    }
    func export(_ recording: Recording, environment: [String: String]) throws -> [URL] {
        let folder = try workFiles(recordingID: recording.id).directory(prefix: "Report-")
        var complete = false
        defer {
            if !complete {
                try? temporaryFiles.remove(folder)
                try? temporaryFiles.removeWorkspaceIfEmpty(recordingID: recording.id)
            }
        }
        let report = Report(recording: recording, environment: environment)
        let json = folder.appendingPathComponent("VoiceBench.json"), md = folder.appendingPathComponent("VoiceBench.md")
        try report.json().write(to: json, options: .atomic)
        try report.markdown().write(to: md, atomically: true, encoding: .utf8)
        complete = true
        return [json, md]
    }
    func removeExport(_ files: [URL]) throws {
        for folder in Set(files.map { $0.deletingLastPathComponent() }) {
            guard folder.lastPathComponent.hasPrefix("Report-") else { throw BenchError("不是临时报告目录。") }
            try temporaryFiles.remove(folder)
            let owner = folder.deletingLastPathComponent().lastPathComponent
            if owner.hasPrefix("Recording-"), let id = UUID(uuidString: String(owner.dropFirst(10))) {
                try temporaryFiles.removeWorkspaceIfEmpty(recordingID: id)
            }
        }
    }
    func removeAllData() throws {
        // Queued editor saves must not resurrect records after the user clears everything.
        deletedRecordings.formUnion(savedRevisions.keys)
        let manager = FileManager.default
        if manager.fileExists(atPath: records.path) {
            for url in try manager.contentsOfDirectory(at: records, includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { deletedRecordings.insert(id) }
            }
        }
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        // The fixed Files-visible source is part of this app's container too. Empty it, then recreate
        // the named folder so the user knows exactly where to put a model next time.
        for url in [defaultModelDirectory, defaultLanguageModelDirectory] {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        try temporaryFiles.reset()
        try Self.prepareDirectories(root: root)
        for var sourceURL in [defaultModelDirectory, defaultLanguageModelDirectory] {
            try manager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            var sourceValues = URLResourceValues(); sourceValues.isExcludedFromBackup = true
            try sourceURL.setResourceValues(sourceValues)
        }
        savedRevisions.removeAll()
    }
}
