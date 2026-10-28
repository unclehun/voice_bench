import Foundation
import VoiceBenchCore

/// Small fake weights exercise storage contracts; they never claim inference accuracy.
enum QwenModelChecks {
    static func run(base: URL) async throws {
        let fm = FileManager.default
        let source = base.appendingPathComponent("ExternalQwen")
        var hashes: [String: String] = [:]
        for name in QwenASRModel.requiredFiles {
            let file = source.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("synthetic Qwen asset: " + name).utf8).write(to: file)
            hashes[name] = try AudioFiles.hash(file)
        }
        let manifest = base.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(hashes).write(to: manifest)
        try Data("fixture license".utf8).write(to: source.appendingPathComponent("LICENSE"))
        let store = try LocalStore(baseURL: base.appendingPathComponent("App"),
            documentsURL: base.appendingPathComponent("Documents"), qwenModelManifestURL: manifest)
        try CleanupChecks.require(await store.qwenModelReceipt() == nil, "New store fabricated a Qwen receipt")
        for name in QwenASRModel.requiredFiles where name != "tokenizer/tokenizer_config.json" {
            let target = store.defaultQwenModelDirectory.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        try CleanupChecks.require(try await store.importDefaultQwenModelsIfComplete() == nil, "Imported unfinished phone transfer")
        var rejected = false
        do { _ = try await store.importDefaultQwenModels() } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted missing tokenizer config")
        let missing = "tokenizer/tokenizer_config.json"
        try fm.copyItem(at: source.appendingPathComponent(missing), to: store.defaultQwenModelDirectory.appendingPathComponent(missing))
        let receipt = try await store.importDefaultQwenModelsIfComplete()
        try CleanupChecks.require(receipt?.files == hashes, "Default Qwen import lost nested assets or hashes")
        try CleanupChecks.require(try await store.importDefaultQwenModelsIfComplete() == nil, "Repeated startup recopied installed Qwen")
        let senseMarker = store.models.appendingPathComponent("sense.keep")
        let whisperMarker = store.languageModels.appendingPathComponent("whisper.keep")
        try CleanupChecks.put(senseMarker); try CleanupChecks.put(whisperMarker)
        _ = try await store.importQwenModels(source)
        try CleanupChecks.require(fm.fileExists(atPath: store.qwenModels.appendingPathComponent("LICENSE").path), "Model license was not imported")
        try CleanupChecks.require(fm.fileExists(atPath: senseMarker.path) && fm.fileExists(atPath: whisperMarker.path), "Qwen replacement touched existing model sets")
        try Data("corrupted transfer".utf8).write(to: source.appendingPathComponent("decoder.int8.onnx"))
        rejected = false
        do { _ = try await store.importQwenModels(source) } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted corrupt Qwen weights")
        try CleanupChecks.require(await store.qwenModelReceipt()?.files == hashes, "Failed replacement destroyed installed Qwen")
        try CleanupChecks.require(try AudioFiles.hash(store.qwenModels.appendingPathComponent("decoder.int8.onnx")) == hashes["decoder.int8.onnx"], "Failed import changed installed decoder")
        try CleanupChecks.require(try fm.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix("Import-") }, "Failed Qwen import leaked staging files")
        for url in [store.qwenModels, store.defaultQwenModelDirectory] {
            try CleanupChecks.require(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "Qwen data still in device backups")
        }
        let reopened = try LocalStore(baseURL: store.root, documentsURL: base.appendingPathComponent("Documents"), qwenModelManifestURL: manifest)
        try CleanupChecks.require(await reopened.qwenModelReceipt()?.files == hashes, "Qwen receipt did not survive restart")
        try await reopened.removeAllData()
        try CleanupChecks.require(await reopened.qwenModelReceipt() == nil, "Clear all kept Qwen receipt")
        for url in [reopened.qwenModels, reopened.defaultQwenModelDirectory] {
            try CleanupChecks.require(try fm.contentsOfDirectory(atPath: url.path).isEmpty, "Clear all left Qwen assets")
        }
        try CleanupChecks.require(fm.fileExists(atPath: source.appendingPathComponent(missing).path), "Clear all deleted external model source")
        if CommandLine.arguments.count > 3 {
            let actualSource = URL(fileURLWithPath: CommandLine.arguments[3])
            let actual = try LocalStore(baseURL: base.appendingPathComponent("ActualQwen"),
                qwenModelManifestURL: URL(fileURLWithPath: "config/qwen-model-manifest.json"))
            let verified = try await actual.importQwenModels(actualSource)
            try CleanupChecks.require(verified.files.count == QwenASRModel.requiredFiles.count, "Actual Qwen assets did not all import")
            try await actual.removeAllData()
            try CleanupChecks.require(await actual.qwenModelReceipt() == nil, "Actual Qwen weights survived clear all")
            print("PASS: full downloaded Qwen model import, pinned SHA-256 and erase")
        }
        print("PASS: Qwen nested/default/manual imports, SHA-256 rejection, atomic replacement, engine isolation, restart, backup exclusion and full erase")
    }
}
