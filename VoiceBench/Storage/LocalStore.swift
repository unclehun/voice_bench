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
    let root: URL
    let models: URL
    let audio: URL
    private let records: URL
    private var savedRevisions: [UUID: Int] = [:]
    private var deletedRecordings = Set<UUID>()
    private let modelManifestURL: URL?
    init(baseURL: URL? = nil, modelManifestURL: URL? = nil) throws {
        let manager = FileManager.default
        self.modelManifestURL = modelManifestURL ?? Bundle.main.url(forResource: "model-manifest", withExtension: "json")
        if let baseURL { root = baseURL }
        else {
            root = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("VoiceBench", isDirectory: true)
        }
        models = root.appendingPathComponent("Models", isDirectory: true)
        audio = root.appendingPathComponent("Audio", isDirectory: true)
        records = root.appendingPathComponent("Records", isDirectory: true)
        for url in [models, audio, records] { try manager.createDirectory(at: url, withIntermediateDirectories: true) }
        var modelURL = models
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try modelURL.setResourceValues(values)
    }
    func load() throws -> [Recording] {
        let urls = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try urls.map { url in
            var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
            recording.recoverInterruptedRuns()
            try save(recording)
            return recording
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func save(_ recording: Recording) throws {
        guard !deletedRecordings.contains(recording.id) else { return }
        guard recording.revision >= savedRevisions[recording.id, default: -1] else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: records.appendingPathComponent(recording.id.uuidString + ".json"), options: .atomic)
        savedRevisions[recording.id] = recording.revision
    }
    func audioURL(_ recording: Recording) -> URL { audio.appendingPathComponent(recording.fileName) }
    func importAudio(_ source: URL) throws -> Recording {
        let ext = source.pathExtension.lowercased()
        guard ["m4a", "wav", "caf"].contains(ext) else { throw BenchError("请选择 M4A 或 WAV 音频。") }
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let name = UUID().uuidString + "." + ext
        let destination = audio.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            let file = try AVAudioFile(forReading: destination)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw BenchError("录音为空。") }
            let item = Recording(name: source.deletingPathExtension().lastPathComponent, fileName: name,
                                 sha256: try AudioFiles.hash(destination), duration: duration,
                                 sampleRate: file.fileFormat.sampleRate, channels: Int(file.fileFormat.channelCount))
            try save(item)
            return item
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    func delete(_ recording: Recording) throws {
        // Remove metadata only after the audio deletion succeeds (if the audio still exists).
        let url = audioURL(recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.removeItem(at: records.appendingPathComponent(recording.id.uuidString + ".json"))
        deletedRecordings.insert(recording.id)
    }
    func modelReceipt() -> ModelReceipt? {
        guard let data = try? Data(contentsOf: models.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(ModelReceipt.self, from: data),
              Self.requiredModels.allSatisfy({ FileManager.default.fileExists(atPath: models.appendingPathComponent($0).path) }) else { return nil }
        return receipt
    }
    func importModels(_ source: URL) throws -> ModelReceipt {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let staging = root.appendingPathComponent("Import-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var hashes: [String: String] = [:]
        for name in Self.requiredModels {
            let input = source.appendingPathComponent(name)
            let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw BenchError("模型文件缺失或为空：\(name)") }
            let output = staging.appendingPathComponent(name)
            try manager.copyItem(at: input, to: output)
            hashes[name] = try AudioFiles.hash(output)
        }
        guard let bundled = modelManifestURL else {
            throw BenchError("App 缺少模型校验清单，请重新构建。")
        }
        let known = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: bundled))
        guard Self.requiredModels.allSatisfy({ known[$0] == hashes[$0] }) else {
            throw BenchError("模型内容与此 Demo 指定版本不一致，请使用配套模型准备脚本。")
        }
        // If the preparation script supplied a manifest, reject changed/corrupt transfers.
        let manifest = source.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: manifest.path) {
            let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
            guard Self.requiredModels.allSatisfy({ expected[$0] == hashes[$0] }) else { throw BenchError("模型 SHA-256 校验失败，请重新传输模型目录。") }
        }
        for name in ["LICENSE", "MODEL_LICENSE", "VAD_LICENSE"] where manager.fileExists(atPath: source.appendingPathComponent(name).path) {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        let receipt = ModelReceipt(version: "sense-voice-int8-2024-07-17", files: hashes, importedAt: Date())
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
        // Atomic directory swap keeps the old model intact if validation/copy fails.
        _ = try manager.replaceItemAt(models, withItemAt: staging)
        var url = models; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return receipt
    }
    func export(_ recording: Recording, environment: [String: String]) throws -> [URL] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report = Report(recording: recording, environment: environment)
        let json = folder.appendingPathComponent("VoiceBench.json"), md = folder.appendingPathComponent("VoiceBench.md")
        try report.json().write(to: json, options: .atomic)
        try report.markdown().write(to: md, atomically: true, encoding: .utf8)
        return [json, md]
    }
}
