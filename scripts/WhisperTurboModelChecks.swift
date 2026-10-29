import Foundation
import VoiceBenchCore

/// Small fake weights exercise storage contracts; they never claim inference accuracy.
enum WhisperTurboModelChecks {
    static func run(base: URL) async throws {
        let fm = FileManager.default
        let source = base.appendingPathComponent("ExternalWhisperTurbo")
        var hashes: [String: String] = [:]
        for name in WhisperTurboModel.requiredFiles {
            let file = source.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("synthetic Whisper Turbo asset: " + name).utf8).write(to: file)
            hashes[name] = try AudioFiles.hash(file)
        }
        let manifest = base.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(hashes).write(to: manifest)
        try Data("fixture license".utf8).write(to: source.appendingPathComponent("LICENSE"))
        let store = try LocalStore(baseURL: base.appendingPathComponent("App"),
            documentsURL: base.appendingPathComponent("Documents"), whisperTurboModelManifestURL: manifest)
        try CleanupChecks.require(await store.whisperTurboModelReceipt() == nil, "New store fabricated a Whisper Turbo receipt")
        for name in WhisperTurboModel.requiredFiles where name != "turbo-tokens.txt" {
            let target = store.defaultWhisperTurboModelDirectory.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(name), to: target)
        }
        try CleanupChecks.require(try await store.importDefaultWhisperTurboModelsIfComplete() == nil, "Imported unfinished phone transfer")
        var rejected = false
        do { _ = try await store.importDefaultWhisperTurboModels() } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted missing token table")
        let missing = "turbo-tokens.txt"
        try fm.copyItem(at: source.appendingPathComponent(missing), to: store.defaultWhisperTurboModelDirectory.appendingPathComponent(missing))
        let receipt = try await store.importDefaultWhisperTurboModelsIfComplete()
        try CleanupChecks.require(receipt?.files == hashes, "Default Whisper Turbo import lost assets or hashes")
        try CleanupChecks.require(try await store.importDefaultWhisperTurboModelsIfComplete() == nil, "Repeated startup recopied installed Whisper Turbo")
        let senseMarker = store.models.appendingPathComponent("sense.keep")
        let whisperMarker = store.languageModels.appendingPathComponent("tiny.keep")
        let qwenMarker = store.qwenModels.appendingPathComponent("qwen.keep")
        let funMarker = store.funASRModels.appendingPathComponent("fun.keep")
        try CleanupChecks.put(senseMarker); try CleanupChecks.put(whisperMarker)
        try CleanupChecks.put(qwenMarker); try CleanupChecks.put(funMarker)
        _ = try await store.importWhisperTurboModels(source)
        try CleanupChecks.require(fm.fileExists(atPath: store.whisperTurboModels.appendingPathComponent("LICENSE").path), "Model license was not imported")
        try CleanupChecks.require(fm.fileExists(atPath: senseMarker.path) && fm.fileExists(atPath: whisperMarker.path) && fm.fileExists(atPath: qwenMarker.path) && fm.fileExists(atPath: funMarker.path), "Whisper Turbo replacement touched existing model sets")
        try Data("corrupted transfer".utf8).write(to: source.appendingPathComponent("turbo-decoder.int8.onnx"))
        rejected = false
        do { _ = try await store.importWhisperTurboModels(source) } catch { rejected = true }
        try CleanupChecks.require(rejected, "Accepted corrupt Whisper Turbo weights")
        try CleanupChecks.require(await store.whisperTurboModelReceipt()?.files == hashes, "Failed replacement destroyed installed Whisper Turbo")
        try CleanupChecks.require(try AudioFiles.hash(store.whisperTurboModels.appendingPathComponent("turbo-decoder.int8.onnx")) == hashes["turbo-decoder.int8.onnx"], "Failed import changed installed decoder")
        try CleanupChecks.require(try fm.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix("Import-") }, "Failed Whisper Turbo import leaked staging files")
        for url in [store.whisperTurboModels, store.defaultWhisperTurboModelDirectory] {
            try CleanupChecks.require(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "Whisper Turbo data still in device backups")
        }
        let reopened = try LocalStore(baseURL: store.root, documentsURL: base.appendingPathComponent("Documents"), whisperTurboModelManifestURL: manifest)
        try CleanupChecks.require(await reopened.whisperTurboModelReceipt()?.files == hashes, "Whisper Turbo receipt did not survive restart")
        try await reopened.removeAllData()
        try CleanupChecks.require(await reopened.whisperTurboModelReceipt() == nil, "Clear all kept Whisper Turbo receipt")
        for url in [reopened.whisperTurboModels, reopened.defaultWhisperTurboModelDirectory] {
            try CleanupChecks.require(try fm.contentsOfDirectory(atPath: url.path).isEmpty, "Clear all left Whisper Turbo assets")
        }
        try CleanupChecks.require(fm.fileExists(atPath: source.appendingPathComponent(missing).path), "Clear all deleted external model source")
        if CommandLine.arguments.count > 5 {
            let actualSource = URL(fileURLWithPath: CommandLine.arguments[5])
            let actual = try LocalStore(baseURL: base.appendingPathComponent("ActualWhisperTurbo"),
                whisperTurboModelManifestURL: URL(fileURLWithPath: "config/whisper-turbo-model-manifest.json"))
            let verified = try await actual.importWhisperTurboModels(actualSource)
            try CleanupChecks.require(verified.files.count == WhisperTurboModel.requiredFiles.count, "Actual Whisper Turbo assets did not all import")
            try await actual.removeAllData()
            try CleanupChecks.require(await actual.whisperTurboModelReceipt() == nil, "Actual Whisper Turbo weights survived clear all")
            print("PASS: full downloaded Whisper Turbo model import, pinned SHA-256 and erase")
        }
        print("PASS: Whisper Turbo default/manual imports, SHA-256 rejection, atomic replacement, engine isolation, restart, backup exclusion and full erase")
    }
}
