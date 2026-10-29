import Foundation
import VoiceBenchCore

/// Full Whisper ASR has its own receipt and storage; old Tiny language-ID assets stay separate.
extension LocalStore {
    func whisperTurboModelReceipt() -> ModelReceipt? {
        guard let data = try? Data(contentsOf: whisperTurboModels.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(ModelReceipt.self, from: data),
              receipt.version == WhisperTurboModel.version,
              WhisperTurboModel.requiredFiles.allSatisfy({ isWhisperTurboAsset(at: whisperTurboModels.appendingPathComponent($0)) }) else { return nil }
        return receipt
    }

    func importDefaultWhisperTurboModelsIfComplete() throws -> ModelReceipt? {
        guard whisperTurboModelReceipt() == nil,
              WhisperTurboModel.requiredFiles.allSatisfy({ isWhisperTurboAsset(at: defaultWhisperTurboModelDirectory.appendingPathComponent($0)) }) else { return nil }
        return try importWhisperTurboModels(defaultWhisperTurboModelDirectory)
    }

    func importDefaultWhisperTurboModels() throws -> ModelReceipt {
        try importWhisperTurboModels(defaultWhisperTurboModelDirectory)
    }

    func importWhisperTurboModels(_ source: URL) throws -> ModelReceipt {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let missing = WhisperTurboModel.requiredFiles.filter { !isWhisperTurboAsset(at: source.appendingPathComponent($0)) }
        guard missing.isEmpty else { throw BenchError("Whisper large-v3-turbo 模型目录缺少或尚未传完：\(missing.joined(separator: "、"))。请复制完整目录。") }
        guard let manifest = whisperTurboModelManifestURL else { throw BenchError("App 缺少 WhisperTurbo 模型校验清单，请重新构建。") }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        guard Set(expected.keys) == Set(WhisperTurboModel.requiredFiles) else { throw BenchError("WhisperTurbo 模型校验清单不完整。") }
        let manager = FileManager.default
        let staging = root.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? AppFileSystem.removeIfPresent(staging) }
        var hashes: [String: String] = [:]
        for name in WhisperTurboModel.requiredFiles {
            let output = staging.appendingPathComponent(name)
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source.appendingPathComponent(name), to: output)
            let hash = try AudioFiles.hash(output)
            guard hash == expected[name] else { throw BenchError("WhisperTurbo 模型 SHA-256 校验失败：\(name)。请使用项目提供的完整配套文件。") }
            hashes[name] = hash
        }
        let sourceManifest = source.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: sourceManifest.path) {
            let supplied = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourceManifest))
            guard WhisperTurboModel.requiredFiles.allSatisfy({ supplied[$0] == hashes[$0] }) else {
                throw BenchError("WhisperTurbo 模型传输清单不匹配，请重新传输。")
            }
        }
        for name in ["LICENSE", "NOTICE", "VAD_LICENSE", "SOURCE.txt"] where manager.fileExists(atPath: source.appendingPathComponent(name).path) {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        let receipt = ModelReceipt(version: WhisperTurboModel.version, files: hashes, importedAt: Date())
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
        // Validation finishes before swapping; a failed import leaves every installed model intact.
        _ = try manager.replaceItemAt(whisperTurboModels, withItemAt: staging)
        var directory = whisperTurboModels
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return receipt
    }

    private func isWhisperTurboAsset(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
