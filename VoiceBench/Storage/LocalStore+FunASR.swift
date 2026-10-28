import Foundation
import VoiceBenchCore

/// FunASR imports are isolated from the existing SenseVoice/Whisper import paths.
extension LocalStore {
    func funASRModelReceipt() -> ModelReceipt? {
        guard let data = try? Data(contentsOf: funASRModels.appendingPathComponent("receipt.json")),
              let receipt = try? JSONDecoder().decode(ModelReceipt.self, from: data),
              receipt.version == FunASRModel.version,
              FunASRModel.requiredFiles.allSatisfy({ isFunASRAsset(at: funASRModels.appendingPathComponent($0)) }) else { return nil }
        return receipt
    }

    func importDefaultFunASRModelsIfComplete() throws -> ModelReceipt? {
        guard funASRModelReceipt() == nil,
              FunASRModel.requiredFiles.allSatisfy({ isFunASRAsset(at: defaultFunASRModelDirectory.appendingPathComponent($0)) }) else { return nil }
        return try importFunASRModels(defaultFunASRModelDirectory)
    }

    func importDefaultFunASRModels() throws -> ModelReceipt {
        try importFunASRModels(defaultFunASRModelDirectory)
    }

    func importFunASRModels(_ source: URL) throws -> ModelReceipt {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let missing = FunASRModel.requiredFiles.filter { !isFunASRAsset(at: source.appendingPathComponent($0)) }
        guard missing.isEmpty else { throw BenchError("Fun-ASR-MLT-Nano 模型目录缺少或尚未传完：\(missing.joined(separator: "、"))。请保留 tokenizer 子目录。") }
        guard let manifest = funASRModelManifestURL else { throw BenchError("App 缺少 FunASR 模型校验清单，请重新构建。") }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        guard Set(expected.keys) == Set(FunASRModel.requiredFiles) else { throw BenchError("FunASR 模型校验清单不完整。") }
        let manager = FileManager.default
        let staging = root.appendingPathComponent("Import-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? AppFileSystem.removeIfPresent(staging) }
        var hashes: [String: String] = [:]
        for name in FunASRModel.requiredFiles {
            let output = staging.appendingPathComponent(name)
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: source.appendingPathComponent(name), to: output)
            let hash = try AudioFiles.hash(output)
            guard hash == expected[name] else { throw BenchError("FunASR 模型 SHA-256 校验失败：\(name)。请使用项目提供的完整配套文件。") }
            hashes[name] = hash
        }
        let sourceManifest = source.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: sourceManifest.path) {
            let supplied = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: sourceManifest))
            guard FunASRModel.requiredFiles.allSatisfy({ supplied[$0] == hashes[$0] }) else {
                throw BenchError("FunASR 模型传输清单不匹配，请重新传输。")
            }
        }
        for name in ["LICENSE", "NOTICE", "VAD_LICENSE", "SOURCE.txt", "EXPORT_METADATA.json"] where manager.fileExists(atPath: source.appendingPathComponent(name).path) {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        let receipt = ModelReceipt(version: FunASRModel.version, files: hashes, importedAt: Date())
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("receipt.json"))
        // Validation finishes before swapping; a failed import leaves every installed model intact.
        _ = try manager.replaceItemAt(funASRModels, withItemAt: staging)
        var directory = funASRModels
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return receipt
    }

    private func isFunASRAsset(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 0
    }
}
