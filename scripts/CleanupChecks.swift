import Foundation
import Darwin
import VoiceBenchCore

/// Real filesystem regressions; no microphone, native ASR or iOS SDK required.
enum CleanupChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BenchError(message) }
    }
    static func expectRejection(_ action: () throws -> Void, _ message: String) throws {
        do { try action() }
        catch { return }
        throw BenchError(message)
    }
    static func physicalURL(_ url: URL) throws -> URL {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else { throw BenchError("Fixture realpath failed") }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
    static func put(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cleanup fixture".utf8).write(to: url)
    }
    static func run(base: URL, source: URL) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let physical = try physicalURL(base)
        // Darwin's physical path includes /private; the Cocoa temp URL often uses /var or /tmp.
        let aliasPath = physical.path.hasPrefix("/private/") ? String(physical.path.dropFirst(8)) : physical.path
        let alias = URL(fileURLWithPath: aliasPath, isDirectory: true)
        fputs("Cleanup regression: physical and alias paths, missing descendants, symlinks and full erase\n", stderr)

        let files = AppTemporaryFiles(root: physical.appendingPathComponent("Temporary", isDirectory: true))
        let aliases = AppTemporaryFiles(root: alias.appendingPathComponent("Temporary", isDirectory: true))
        try files.reset()
        let id = UUID()
        let workspace = files.workspace(recordingID: id)
        // Original bug: root exists with /private, but this recording's folder never existed.
        try files.remove(workspace.root)
        try aliases.remove(workspace.root)
        try files.remove(aliases.workspace(recordingID: id).root)
        try files.removeWorkspaceIfEmpty(recordingID: id)
        try put(workspace.root.appendingPathComponent("LanguageID-tail.caf"))
        try files.remove(workspace.root)
        try files.remove(workspace.root) // normal post-inference/delete retry, target now absent.
        try files.remove(workspace.root.appendingPathComponent("nested/never-created.caf"))
        try manager.removeItem(at: files.root)
        try files.remove(workspace.root) // even the temporary root was purged by the OS.
        try files.removeWorkspaceIfEmpty(recordingID: id)
        try files.reset()

        let outside = physical.appendingPathComponent("Outside", isDirectory: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try put(keep)
        try expectRejection({ try files.remove(keep) }, "Allowed an external file")
        try expectRejection({ try files.remove(outside.appendingPathComponent("missing.txt")) }, "Allowed a missing external path")
        try expectRejection({ try files.remove(files.root) }, "Allowed removal of the protected root itself")
        let sibling = physical.appendingPathComponent("Temporary-sibling/keep.txt")
        try put(sibling)
        try expectRejection({ try files.remove(sibling) }, "String-prefix sibling escaped the boundary")
        try expectRejection({ try files.remove(files.root.appendingPathComponent("../Outside/keep.txt")) }, "Allowed a parent-directory escape")
        try expectRejection({ try files.remove(URL(string: "https://example.invalid/file")!) }, "Allowed non-file URL")
        let escape = files.root.appendingPathComponent("escape", isDirectory: true)
        try manager.createSymbolicLink(at: escape, withDestinationURL: outside)
        try expectRejection({ try files.remove(escape.appendingPathComponent("keep.txt")) }, "Followed a symlink to an external file")
        try expectRejection({ try files.remove(escape.appendingPathComponent("missing/nested.txt")) }, "Followed a symlink to a missing external descendant")
        let broken = files.root.appendingPathComponent("broken", isDirectory: true)
        try manager.createSymbolicLink(at: broken, withDestinationURL: outside.appendingPathComponent("absent", isDirectory: true))
        try expectRejection({ try files.remove(broken.appendingPathComponent("missing.txt")) }, "Accepted a dangling ancestor as safely absent")
        try files.remove(escape) // delete only the owned link entry, never the external directory.
        try files.remove(broken)
        try require(!manager.fileExists(atPath: escape.path) && manager.fileExists(atPath: keep.path), "Unlinking an owned link deleted external contents")
        let internalDirectory = files.root.appendingPathComponent("Internal", isDirectory: true)
        try put(internalDirectory.appendingPathComponent("derived.caf"))
        let internalAlias = files.root.appendingPathComponent("InternalAlias", isDirectory: true)
        try manager.createSymbolicLink(at: internalAlias, withDestinationURL: internalDirectory)
        try files.remove(internalAlias.appendingPathComponent("derived.caf"))
        try require(!manager.fileExists(atPath: internalDirectory.appendingPathComponent("derived.caf").path), "Rejected a safe internal symlink path")
        try files.reset() // all links inside root are unlinked; external contents remain.
        try require(manager.fileExists(atPath: keep.path), "Reset deleted a symlink target")
        try require(try manager.contentsOfDirectory(atPath: files.root.path).isEmpty, "Reset left links or files")
        try manager.removeItem(at: files.root)
        try manager.createSymbolicLink(at: files.root, withDestinationURL: outside)
        try expectRejection({ try files.remove(files.root.appendingPathComponent("keep.txt")) }, "Accepted a substituted root symlink")
        try files.reset()
        try require(manager.fileExists(atPath: keep.path), "Reset followed a substituted root symlink")

        let appRoot = physical.appendingPathComponent("ApplicationSupport/VoiceBench", isDirectory: true)
        let documents = physical.appendingPathComponent("Documents", isDirectory: true)
        let temp = AppTemporaryFiles(root: physical.appendingPathComponent("AppTemporary", isDirectory: true))
        let legacy = physical.appendingPathComponent("LegacyTemporary", isDirectory: true)
        let store = try LocalStore(baseURL: appRoot, temporaryFiles: temp, documentsURL: documents,
                                   legacyTemporaryDirectory: legacy)
        let credentials = DeepSeekCredentialStore(baseURL: appRoot)
        try credentials.save("sk-synthetic-cleanup-key")
        let credentialFile = try credentials.fileURL
        let item = try await store.importAudio(source)
        let second = try await store.importAudio(source)
        // Reproduce the user's delete path: successful inference already removed the work directory.
        let work = await store.workFiles(recordingID: item.id)
        try put(work.root.appendingPathComponent("audio.caf"))
        try temp.remove(work.root)
        try await store.delete(item)
        try await store.delete(item)
        try await store.save(item)
        try require(try await store.load().map(\.id) == [second.id], "Delete with absent work directory failed or resurrected metadata")
        let brokenRecord = try await store.importAudio(source)
        let brokenWork = await store.workFiles(recordingID: brokenRecord.id)
        try manager.createSymbolicLink(at: brokenWork.root, withDestinationURL: outside.appendingPathComponent("absent"))
        try await store.delete(brokenRecord)
        try require(try await store.load().map(\.id) == [second.id], "Broken work-directory entry blocked complete recording deletion")
        for url in [store.models.appendingPathComponent("model.bin"), store.languageModels.appendingPathComponent("encoder.bin"),
                    store.qwenModels.appendingPathComponent("tokenizer/vocab.json"),
                    store.qwenWeightOnlyModels.appendingPathComponent("decoder.weight4.onnx"),
                    store.funASRModels.appendingPathComponent("tokenizer/tokenizer.json"),
                    store.whisperTurboModels.appendingPathComponent("turbo-encoder.int8.onnx"),
                    store.defaultModelDirectory.appendingPathComponent("source.onnx"),
                    store.defaultLanguageModelDirectory.appendingPathComponent("source.onnx"),
                    store.defaultQwenModelDirectory.appendingPathComponent("tokenizer/vocab.json"),
                    store.defaultQwenWeightOnlyModelDirectory.appendingPathComponent("decoder.weight4.onnx"),
                    store.defaultFunASRModelDirectory.appendingPathComponent("tokenizer/tokenizer.json"),
                    store.defaultWhisperTurboModelDirectory.appendingPathComponent("turbo-decoder.int8.onnx"),
                    appRoot.appendingPathComponent("Import-" + UUID().uuidString + "/partial.bin"),
                    appRoot.appendingPathComponent("unexpected.bin"), temp.root.appendingPathComponent("录音-partial.m4a")] {
            try put(url)
        }
        let report = try await store.export(second, environment: [:])
        let secondWork = await store.workFiles(recordingID: second.id)
        try put(secondWork.root.appendingPathComponent("nested/partial.caf"))
        try manager.createSymbolicLink(at: secondWork.root.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
        for name in [UUID().uuidString + ".caf", "Report-" + UUID().uuidString + "/report.json", "录音-legacy.m4a", "unrelated.keep"] {
            try put(legacy.appendingPathComponent(name))
        }
        try await store.removeAllData()
        try require(!manager.fileExists(atPath: credentialFile.path), "Erase all retained DeepSeek API Key configuration")
        try require(try credentials.read() == nil, "Erase all restored a deleted API Key")
        let newCredentials = DeepSeekCredentialStore(baseURL: appRoot)
        try require(try newCredentials.read() == nil, "Relaunch after erase all restored an API Key")
        // Exercise another clear with a dangling default folder; fileExists alone misses it.
        try manager.removeItem(at: store.defaultLanguageModelDirectory)
        try manager.createSymbolicLink(at: store.defaultLanguageModelDirectory, withDestinationURL: outside.appendingPathComponent("missing"))
        try await store.removeAllData()
        try manager.removeItem(at: store.defaultQwenModelDirectory)
        try manager.createSymbolicLink(at: store.defaultQwenModelDirectory, withDestinationURL: outside.appendingPathComponent("missing-qwen"))
        try await store.removeAllData()
        try manager.removeItem(at: store.defaultFunASRModelDirectory)
        try manager.createSymbolicLink(at: store.defaultFunASRModelDirectory, withDestinationURL: outside.appendingPathComponent("missing-funasr"))
        try await store.removeAllData()
        try manager.removeItem(at: store.defaultWhisperTurboModelDirectory)
        try manager.createSymbolicLink(at: store.defaultWhisperTurboModelDirectory, withDestinationURL: outside.appendingPathComponent("missing-turbo"))
        try await store.removeAllData()
        try await store.save(second)
        try await store.removeExport(report)
        try require(try await store.load().isEmpty, "Erase all resurrected a recording")
        let senseReceipt = await store.modelReceipt(), whisperReceipt = await store.languageModelReceipt(), qwenReceipt = await store.qwenModelReceipt(), funASRReceipt = await store.funASRModelReceipt(), turboReceipt = await store.whisperTurboModelReceipt()
        try require(senseReceipt == nil && whisperReceipt == nil && qwenReceipt == nil && funASRReceipt == nil && turboReceipt == nil, "Erase all retained model receipts")
        for url in [store.audio, store.models, store.languageModels, store.qwenModels, store.qwenWeightOnlyModels, store.funASRModels, store.whisperTurboModels, store.root.appendingPathComponent("Records"),
                    store.defaultModelDirectory, store.defaultLanguageModelDirectory, store.defaultQwenModelDirectory, store.defaultQwenWeightOnlyModelDirectory, store.defaultFunASRModelDirectory, store.defaultWhisperTurboModelDirectory, temp.root] {
            try require(try manager.contentsOfDirectory(atPath: url.path).isEmpty, "Erase all left files in \(url.lastPathComponent)")
        }
        try require(Set(try manager.contentsOfDirectory(atPath: appRoot.path)) == Set(["Audio", "Models", "LanguageIDModels", "QwenModels", "QwenWeightOnlyModels", "FunASRModels", "Records", "WhisperTurboModels"]), "Erase all left abandoned imports or unknown files")
        try require(try manager.contentsOfDirectory(atPath: legacy.path) == ["unrelated.keep"], "Legacy cleanup leaked known files or deleted unrelated content")
        try require(manager.fileExists(atPath: keep.path) && manager.fileExists(atPath: source.path), "Erase all deleted external data")
        _ = try await store.importAudio(source)
        let reopened = try LocalStore(baseURL: appRoot, temporaryFiles: temp, documentsURL: documents)
        try require(try await reopened.load().count == 1, "Storage could not be reused after erase all")
        try await reopened.removeAllData()

        // Fail one independent cleanup target: other targets still clear, success is never reported.
        let failedParent = physical.appendingPathComponent("BlockedTemporary", isDirectory: true)
        let failedTemp = AppTemporaryFiles(root: failedParent.appendingPathComponent("Temporary", isDirectory: true))
        let failureStore = try LocalStore(baseURL: physical.appendingPathComponent("FailureStore"), temporaryFiles: failedTemp,
                                          documentsURL: physical.appendingPathComponent("FailureDocuments"))
        _ = try await failureStore.importAudio(source)
        try put(failureStore.defaultModelDirectory.appendingPathComponent("model.bin"))
        try manager.removeItem(at: failedParent)
        try Data("parent replaced by a regular file".utf8).write(to: failedParent)
        var failed = false
        do { try await failureStore.removeAllData() } catch { failed = true }
        try require(failed, "Erase all hid an inaccessible cleanup target")
        try require(try await failureStore.load().isEmpty, "One failed target prevented independent recording cleanup")
        try require(try manager.contentsOfDirectory(atPath: failureStore.defaultModelDirectory.path).isEmpty, "One failed target prevented default model cleanup")
        try manager.removeItem(at: failedParent)
        try await failureStore.removeAllData() // repair + retry completes all targets.
        fputs("PASS: physical/alias/missing paths, boundary and symlink protection, delete retry, complete erase, legacy leftovers, failure reporting and retry\n", stderr)
    }
}
