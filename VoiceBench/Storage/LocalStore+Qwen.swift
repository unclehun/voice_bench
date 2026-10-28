import Foundation
import VoiceBenchCore

/// Qwen imports are isolated from the existing SenseVoice/Whisper import paths.
extension LocalStore {
    func qwenModelReceipt() -> ModelReceipt? {
        guard let data = try? Data(contentsOf: qwenModels.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(ModelReceipt.self, from: data),
              receipt.version == QwenASRModel.version,
              QwenASRModel.requiredFiles.allSatisfy({ isQwenAsset(at: qwenModels.appendingPathComponent($0)) }) else { return nil }
        return receipt
    }

    func importDefaultQwenModelsIfComplete() throws -> ModelReceipt? {
        guard qwenModelReceipt() == nil,
              QwenASRModel.requiredFiles.allSatisfy({ isQwenAsset(at: defaultQwenModelDirectory.appendingPathComponent($0)) }) else { return nil }
        return try importQwenModels(defaultQwenModelDirectory)
    }

    func importDefaultQwenModels() throws -> ModelReceipt {
        try importQwenModels(defaultQwenModelDirectory)
    }

    func importQwenModels(_ source: URL) throws -> ModelReceipt {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let missing = QwenASRModel.requiredFiles.filter { !isQwenAsset(at: source.appendingPathComponent($0)) }
        guard missing.isEmpty else { throw BenchError("Qwen3-ASR 模型目录缺少或尚未传完：\(missing.joined(separator: "、"))。请保留 tokenizer 子目录。") }
        guard let manifest = qwenModelManifestURL else { throw BenchError("App 缺少 Qwen 模型校验清单，请重新构建。") }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        guard Set(expected.keys) == Set(QwenASRModel.requiredFiles) else { throw BenchError("Qwen 模型校验清单不完整。") }
        let manager = FileManager.default
        let staging = root.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? AppFileSystem.removeIfPresent(staging) }
        var hashes: [String: String] = [:]
        for name in QwenASRModel.requiredFiles {
            let output = staging.appendingPathComponent(name)
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source.appendingPathComponent(name), to: output)
            let hash = try AudioFiles.hash(output)
            guard hash == expected[name] else { throw BenchError("Qwen 模型 SHA-256 校验失败：\(name)。请使用项目提供的完整配套文件。") }
            hashes[name] = hash
        }
        let sourceManifest = source.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: sourceManifest.path) {
            let supplied = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourceManifest))
            guard QwenASRModel.requiredFiles.allSatisfy({ supplied[$0] == hashes[$0] }) else {
                throw BenchError("Qwen 模型传输清单不匹配，请重新传输。")
            }
        }
        for name in ["LICENSE", "NOTICE", "VAD_LICENSE", "SOURCE.txt"] where manager.fileExists(atPath: source.appendingPathComponent(name).path) {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        let receipt = ModelReceipt(version: QwenASRModel.version, files: hashes, importedAt: Date())
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
        // Validation finishes before swapping; a failed import leaves every installed model intact.
        _ = try manager.replaceItemAt(qwenModels, withItemAt: staging)
        var directory = qwenModels
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return receipt
    }

    private func isQwenAsset(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
