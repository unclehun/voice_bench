import Foundation
import VoiceBenchCore

/// Small fake weights exercise storage contracts; they never claim inference accuracy.
enum FunASRModelChecks {
    static func run(base: URL) async throws {
        let fm = FileManager.default
        let source = base.appendingPathComponent("ExternalFunASR")
        var hashes: [String: String] = [:]
        for name in FunASRModel.requiredFiles {
            let file = source.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("synthetic FunASR asset: " + name).utf8).write(to: file)
            hashes[name] = try AudioFiles.hash(file)
        }
        let manifest = base.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(hashes).write(to: manifest)
        try Data("fixture license".utf8).write(to: source.appendingPathComponent("LICENSE"))
        let store = try LocalStore(baseURL: base.appendingPathComponent("App"),
            documentsURL: base.appendingPathComponent("Documents"), funASRModelManifestURL: manifest)
        try CleanupChecks.require(await store.funASRModelReceipt() == nil, "New store fabricated a FunASR receipt")
        for name in FunASRModel.requiredFiles where name != "tokenizer/tokenizer_config.json" {
            let target = store.defaultFunASRModelDirectory.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        try CleanupChecks.require(try await store.importDefaultFunASRModelsIfComplete() == nil, "Imported unfinished phone transfer")
        var rejected = false
        do { _ = try await store.importDefaultFunASRModels() } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted missing tokenizer config")
        let missing = "tokenizer/tokenizer_config.json"
        try fm.copyItem(at: source.appendingPathComponent(missing), to: store.defaultFunASRModelDirectory.appendingPathComponent(missing))
        let receipt = try await store.importDefaultFunASRModelsIfComplete()
        try CleanupChecks.require(receipt?.files == hashes, "Default FunASR import lost nested assets or hashes")
        try CleanupChecks.require(try await store.importDefaultFunASRModelsIfComplete() == nil, "Repeated startup recopied installed FunASR")
        let senseMarker = store.models.appendingPathComponent("sense.keep")
        let whisperMarker = store.languageModels.appendingPathComponent("whisper.keep")
        let qwenMarker = store.qwenModels.appendingPathComponent("qwen.keep")
        try CleanupChecks.put(senseMarker); try CleanupChecks.put(whisperMarker); try CleanupChecks.put(qwenMarker)
        _ = try await store.importFunASRModels(source)
        try CleanupChecks.require(fm.fileExists(atPath: store.funASRModels.appendingPathComponent("LICENSE").path), "Model license was not imported")
        try CleanupChecks.require(fm.fileExists(atPath: senseMarker.path) && fm.fileExists(atPath: whisperMarker.path) && fm.fileExists(atPath: qwenMarker.path), "FunASR replacement touched existing model sets")
        try Data("corrupted transfer".utf8).write(to: source.appendingPathComponent("llm.int8.onnx"))
        rejected = false
        do { _ = try await store.importFunASRModels(source) } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted corrupt FunASR weights")
        try CleanupChecks.require(await store.funASRModelReceipt()?.files == hashes, "Failed replacement destroyed installed FunASR")
        try CleanupChecks.require(try AudioFiles.hash(store.funASRModels.appendingPathComponent("llm.int8.onnx")) == hashes["llm.int8.onnx"], "Failed import changed installed decoder")
        try CleanupChecks.require(try fm.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix("Import-") }, "Failed FunASR import leaked staging files")
        for url in [store.funASRModels, store.defaultFunASRModelDirectory] {
            try CleanupChecks.require(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "FunASR data still in device backups")
        }
        let reopened = try LocalStore(baseURL: store.root, documentsURL: base.appendingPathComponent("Documents"), funASRModelManifestURL: manifest)
        try CleanupChecks.require(await reopened.funASRModelReceipt()?.files == hashes, "FunASR receipt did not survive restart")
        try await reopened.removeAllData()
        try CleanupChecks.require(await reopened.funASRModelReceipt() == nil, "Clear all kept FunASR receipt")
        for url in [reopened.funASRModels, reopened.defaultFunASRModelDirectory] {
            try CleanupChecks.require(try fm.contentsOfDirectory(atPath: url.path).isEmpty, "Clear all left FunASR assets")
        }
        try CleanupChecks.require(fm.fileExists(atPath: source.appendingPathComponent(missing).path), "Clear all deleted external model source")
        if CommandLine.arguments.count > 4 {
            let actualSource = URL(fileURLWithPath: CommandLine.arguments[4])
            let actual = try LocalStore(baseURL: base.appendingPathComponent("ActualFunASR"),
                funASRModelManifestURL: URL(fileURLWithPath: "config/funasr-mlt-model-manifest.json"))
            let verified = try await actual.importFunASRModels(actualSource)
            try CleanupChecks.require(verified.files.count == FunASRModel.requiredFiles.count, "Actual FunASR assets did not all import")
            try await actual.removeAllData()
            try CleanupChecks.require(await actual.funASRModelReceipt() == nil, "Actual FunASR weights survived clear all")
            print("PASS: full downloaded FunASR model import, pinned SHA-256 and erase")
        }
        print("PASS: FunASR nested/default/manual imports, SHA-256 rejection, atomic replacement, engine isolation, restart, backup exclusion and full erase")
    }
}
