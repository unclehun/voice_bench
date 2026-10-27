import Foundation
import AVFoundation
import VoiceBenchCore

@main
struct AudioChecks {
    static func main() async {
        do { try await checks() }
        catch { fputs("FAIL: \(String(reflecting: error))\n", stderr); exit(1) }
    }
    static func checks() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchAudioChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await languageModelStorageChecks(base: base.appendingPathComponent("ModelFixtures"))
        let source = base.appendingPathComponent("synthetic.wav")
        fputs("Audio check: create source\n", stderr)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: source, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 49123)!
            buffer.frameLength = 49123
            for c in 0..<2 { for i in 0..<49123 { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 0.03)) * 0.1 } }
            try file.write(from: buffer)
        }
        let output = base.appendingPathComponent("converted.caf")
        fputs("Audio check: convert\n", stderr)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        try AudioFiles.convert(source: source, target: output, format: target, cancellation: CancellationFlag())
        let file = try AVAudioFile(forReading: output)
        fputs("Audio check: verify output \(file.length) frames\n", stderr)
        guard abs(Double(file.length) - 49123.0 / 3) <= 2, file.processingFormat.channelCount == 1 else {
            throw BenchError("Resampling dropped or duplicated audio frames: \(file.length)")
        }
        let hash = try AudioFiles.hash(source)
        fputs("Audio check: cancellation\n", stderr)
        guard hash.count == 64 else { throw BenchError("SHA-256 format") }
        let flag = CancellationFlag(); flag.cancel()
        do {
            try AudioFiles.convert(source: source, target: base.appendingPathComponent("cancelled.caf"), format: target, cancellation: flag)
            throw BenchError("Cancellation not honored")
        } catch is CancellationError { }
        guard !FileManager.default.fileExists(atPath: base.appendingPathComponent("cancelled.caf").path) else {
            throw BenchError("Cancelled conversion left a partial output")
        }
        let store = try LocalStore(baseURL: base.appendingPathComponent("Store"),
                                  modelManifestURL: URL(fileURLWithPath: "config/model-manifest.json"),
                                  languageModelManifestURL: URL(fileURLWithPath: "config/language-model-manifest.json"))
        guard FileManager.default.fileExists(atPath: store.defaultModelDirectory.path) else {
            throw BenchError("Default Files-visible model directory was not created")
        }
        fputs("Audio check: import and persist\n", stderr)
        var item = try await store.importAudio(source, displayName: "录音 1")
        guard item.sha256 == hash, item.channels == 2, item.name == "录音 1" else { throw BenchError("Import metadata / recording name") }
        item.reference = "新版"; item.revision = 2
        try await store.save(item)
        var stale = item; stale.reference = "旧版"; stale.revision = 1
        try await store.save(stale)
        let loaded = try await store.load()
        guard loaded.count == 1, loaded[0].reference == "新版" else { throw BenchError("Stale save overwrote newer data") }
        try await recordingDeletionChecks(store: store, source: source, keep: item)
        fputs("Storage check: backups, exports, invalid import and cold-launch recovery\n", stderr)
        let root = store.root
        for name in ["", "Audio", "Records", "Models", "LanguageIDModels"] {
            let url = name.isEmpty ? root : root.appendingPathComponent(name)
            guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
                throw BenchError("App data directory still included in backup: \(name)")
            }
        }
        guard try store.defaultModelDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw BenchError("Default model source directory still included in backup")
        }
        let exports = try await store.export(item, environment: [:])
        guard exports.count == 2, exports.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw BenchError("Report export") }
        let externalCopy = base.appendingPathComponent("UserSavedReport.json")
        try FileManager.default.copyItem(at: exports[0], to: externalCopy)
        try await store.removeExport(exports)
        guard !FileManager.default.fileExists(atPath: exports[0].deletingLastPathComponent().path),
              FileManager.default.fileExists(atPath: externalCopy.path) else { throw BenchError("Share cleanup removed user copy or left staging files") }
        let temporary = store.temporaryFiles
        var invalidReport = item; invalidReport.duration = .infinity
        do { _ = try await store.export(invalidReport, environment: [:]); throw BenchError("Invalid report unexpectedly exported") }
        catch { if error.localizedDescription == "Invalid report unexpectedly exported" { throw error } }
        guard try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty else { throw BenchError("Failed export leaked files") }
        do { try temporary.remove(externalCopy); throw BenchError("Allowed deleting external file") }
        catch { if error.localizedDescription == "Allowed deleting external file" { throw error } }
        let invalidAudio = base.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: invalidAudio)
        do { _ = try await store.importAudio(invalidAudio); throw BenchError("Invalid audio unexpectedly imported") }
        catch { if error.localizedDescription == "Invalid audio unexpectedly imported" { throw error } }
        let audioDirectory = store.audio
        guard try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).count == 1 else { throw BenchError("Failed import leaked audio") }
        let abandonedAudio = audioDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("partial import".utf8).write(to: abandonedAudio)
        let abandonedModel = root.appendingPathComponent("Import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: abandonedModel, withIntermediateDirectories: true)
        let abandonedReport = try await store.export(item, environment: [:])
        let abandonedRecording = try temporary.file(extension: "m4a", prefix: "录音-")
        try Data("partial recording".utf8).write(to: abandonedRecording)
        let reopened = try LocalStore(baseURL: root)
        let recovered = try await reopened.load()
        guard recovered.count == 1, recovered[0].reference == "新版",
              !FileManager.default.fileExists(atPath: abandonedModel.path),
              !FileManager.default.fileExists(atPath: abandonedAudio.path),
              !FileManager.default.fileExists(atPath: abandonedReport[0].path),
              !FileManager.default.fileExists(atPath: abandonedRecording.path) else { throw BenchError("Cold launch recovery left abandoned files or lost saved data") }
        do {
            fputs("Audio check: reject missing model\n", stderr)
            _ = try await store.importModels(base)
            throw BenchError("Accepted incomplete model folder")
        } catch { guard !(error is BenchError) || error.localizedDescription != "Accepted incomplete model folder" else { throw error } }
        if CommandLine.arguments.count > 1 {
            fputs("Audio check: import full pinned model directory\n", stderr)
            let folder = URL(fileURLWithPath: CommandLine.arguments[1])
            fputs("Audio check: default model directory auto-discovery\n", stderr)
            for name in LocalStore.requiredModels + ["manifest.json"] {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: store.defaultModelDirectory.appendingPathComponent(name))
            }
            let defaultReceipt = try await store.importDefaultModelsIfComplete()
            guard defaultReceipt?.files.count == 3, await store.modelReceipt()?.files == defaultReceipt?.files else {
                throw BenchError("Default model directory was not automatically imported")
            }
            guard try await store.importDefaultModelsIfComplete() == nil else {
                throw BenchError("Default model directory overwrote an installed model on repeat launch")
            }
            let receipt = try await store.importModels(folder)
            guard receipt.files.count == 3, await store.modelReceipt() != nil else { throw BenchError("Model import did not persist") }
            fputs("Audio check: repeat model replacement\n", stderr)
            _ = try await store.importModels(folder)
            let tiny = base.appendingPathComponent("InvalidModels")
            try FileManager.default.createDirectory(at: tiny, withIntermediateDirectories: true)
            for name in LocalStore.requiredModels { try Data("corrupt".utf8).write(to: tiny.appendingPathComponent(name)) }
            do { _ = try await store.importModels(tiny); throw BenchError("Accepted corrupt models") }
            catch { guard !error.localizedDescription.contains("Accepted corrupt") else { throw error } }
            guard await store.modelReceipt()?.files == receipt.files else { throw BenchError("Failed import destroyed old models") }
        }
        if CommandLine.arguments.count > 2 {
            fputs("Audio check: full pinned Whisper directory and independence from SenseVoice replacement\n", stderr)
            let folder = URL(fileURLWithPath: CommandLine.arguments[2])
            for name in LocalStore.requiredLanguageModels + ["manifest.json"] {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: store.defaultLanguageModelDirectory.appendingPathComponent(name))
            }
            let receipt = try await store.importDefaultLanguageModelsIfComplete()
            guard receipt?.files.count == 3, await store.languageModelReceipt()?.files == receipt?.files,
                  try await store.importDefaultLanguageModelsIfComplete() == nil else { throw BenchError("Full Whisper default import") }
            _ = try await store.importLanguageModels(folder)
            if CommandLine.arguments.count > 1 {
                _ = try await store.importModels(URL(fileURLWithPath: CommandLine.arguments[1]))
                guard await store.languageModelReceipt()?.files == receipt?.files else { throw BenchError("SenseVoice replacement deleted Whisper") }
            }
        }
        try await store.delete(item)
        try await store.save(stale)
        fputs("Audio check: deletion\n", stderr)
        guard try await store.load().isEmpty else { throw BenchError("Delete failed") }
        fputs("Storage check: erase all, stale saves and external-file preservation\n", stderr)
        let another = try await store.importAudio(source)
        _ = try await store.export(another, environment: [:])
        let modelDirectory = store.models
        try Data("model cleanup fixture".utf8).write(to: modelDirectory.appendingPathComponent("extra-file"))
        try await store.removeAllData()
        try await store.removeAllData() // Idempotent, including an already empty store.
        try await store.save(another)
        guard try await store.load().isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: audioDirectory.path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: modelDirectory.path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: store.languageModels.path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: store.defaultModelDirectory.path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: store.defaultLanguageModelDirectory.path).isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty,
              FileManager.default.fileExists(atPath: externalCopy.path),
              FileManager.default.fileExists(atPath: source.path) else { throw BenchError("Clear all left app files, resurrected data or deleted external inputs") }
        _ = try await store.importAudio(source)
        guard try await store.load().count == 1 else { throw BenchError("Cannot reuse store after clearing") }
        let legacy = base.appendingPathComponent("LegacyTmp")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        for name in [UUID().uuidString + ".caf", "Report-" + UUID().uuidString, "录音-12-34-56.m4a", "unrelated.keep"] {
            try Data("fixture".utf8).write(to: legacy.appendingPathComponent(name))
        }
        try AppTemporaryFiles.removeLegacyFiles(in: legacy)
        guard try FileManager.default.contentsOfDirectory(atPath: legacy.path) == ["unrelated.keep"] else { throw BenchError("Legacy cleanup scope") }
        print("PASS: real resampling, cancellation, hashing, persistence, backup exclusion, export cleanup, failure cleanup, crash recovery, model import, erase-all and external-file preservation. No microphone, ASR or iOS uninstall test performed.")
    }

    static func languageModelStorageChecks(base: URL) async throws {
        fputs("Model storage check: synthetic manifests, defaults, atomic failure and independent model sets\n", stderr)
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        func fixture(_ name: String, required: [String]) throws -> (URL, URL, [String: String]) {
            let source = base.appendingPathComponent(name)
            try manager.createDirectory(at: source, withIntermediateDirectories: true)
            var hashes: [String: String] = [:]
            for file in required {
                let url = source.appendingPathComponent(file)
                try Data("synthetic \(name) \(file)".utf8).write(to: url)
                hashes[file] = try AudioFiles.hash(url)
            }
            let manifest = source.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(hashes).write(to: manifest)
            return (source, manifest, hashes)
        }
        let (senseSource, senseManifest, senseHashes) = try fixture("Sense", required: LocalStore.requiredModels)
        let (whisperSource, whisperManifest, whisperHashes) = try fixture("Whisper", required: LocalStore.requiredLanguageModels)
        let store = try LocalStore(baseURL: base.appendingPathComponent("Store"), modelManifestURL: senseManifest,
                                   languageModelManifestURL: whisperManifest)
        guard try await store.importDefaultLanguageModelsIfComplete() == nil else { throw BenchError("Empty default Whisper was imported") }
        let source = store.defaultLanguageModelDirectory
        guard source.lastPathComponent == "WhisperTiny_INT8",
              try source.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw BenchError("Whisper default directory/backup policy") }
        try manager.copyItem(at: whisperSource.appendingPathComponent(LocalStore.requiredLanguageModels[0]),
                             to: source.appendingPathComponent(LocalStore.requiredLanguageModels[0]))
        guard try await store.importDefaultLanguageModelsIfComplete() == nil else { throw BenchError("Partial Whisper transfer was imported") }
        for name in LocalStore.requiredLanguageModels.dropFirst() + ["manifest.json"] {
            try manager.copyItem(at: whisperSource.appendingPathComponent(name), to: source.appendingPathComponent(name))
        }
        let first = try await store.importDefaultLanguageModelsIfComplete()
        guard first?.files == whisperHashes, first?.version == LanguageDetection.modelVersion,
              try await store.importDefaultLanguageModelsIfComplete() == nil else { throw BenchError("Whisper default discovery/idempotence") }
        _ = try await store.importModels(senseSource)
        _ = try await store.importModels(senseSource)
        guard await store.languageModelReceipt()?.files == whisperHashes else { throw BenchError("Sense replacement changed Whisper") }
        _ = try await store.importLanguageModels(whisperSource)
        _ = try await store.importDefaultLanguageModels()
        guard await store.modelReceipt()?.files == senseHashes else { throw BenchError("Whisper replacement changed Sense") }
        let corrupt = base.appendingPathComponent("Corrupt")
        try manager.copyItem(at: whisperSource, to: corrupt)
        try Data("damaged".utf8).write(to: corrupt.appendingPathComponent(LocalStore.requiredLanguageModels[0]))
        do { _ = try await store.importLanguageModels(corrupt); throw BenchError("Accepted corrupt Whisper") }
        catch { if error.localizedDescription == "Accepted corrupt Whisper" { throw error } }
        guard await store.languageModelReceipt()?.files == whisperHashes else { throw BenchError("Failed import destroyed working Whisper") }
        let pending = try manager.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix("Import-") }
        guard pending.isEmpty else { throw BenchError("Whisper staging folder leaked") }
        let reopened = try LocalStore(baseURL: store.root, modelManifestURL: senseManifest, languageModelManifestURL: whisperManifest)
        guard await reopened.languageModelReceipt()?.files == whisperHashes else { throw BenchError("Whisper not persisted across launch") }
        try await reopened.removeAllData()
        guard await reopened.modelReceipt() == nil, await reopened.languageModelReceipt() == nil,
              try manager.contentsOfDirectory(atPath: reopened.defaultLanguageModelDirectory.path).isEmpty,
              manager.fileExists(atPath: whisperSource.appendingPathComponent(LocalStore.requiredLanguageModels[0]).path) else {
            throw BenchError("Erase all did not clear Whisper, or removed external originals")
        }
    }

    static func recordingDeletionChecks(store: LocalStore, source: URL, keep: Recording) async throws {
        fputs("Recording card check: deleting one record clears every run and its workspace, preserves other records/models\n", stderr)
        var removed = try await store.importAudio(source)
        let batch = UUID()
        for engine in EngineID.allCases {
            var run = Run(engine: engine)
            run.batchID = batch; run.status = .completed; run.rawText = "synthetic transcript"
            run.correction.status = "completed"; run.correction.text = "synthetic correction"
            removed.runs.append(run)
        }
        removed.reference = "fixture reference"; removed.context = "fixture context"; removed.revision += 1
        try await store.save(removed)
        let report = try await store.export(removed, environment: [:])
        let work = await store.workFiles(recordingID: removed.id)
        let derived = try work.file(extension: "caf")
        try Data("interrupted derived audio".utf8).write(to: derived)
        let languageAudio = try work.file(extension: "caf", prefix: "LanguageID-")
        try Data("interrupted language detection".utf8).write(to: languageAudio)
        let anotherWork = await store.workFiles(recordingID: keep.id)
        let preserved = try anotherWork.file(extension: "caf")
        try Data("other recording work".utf8).write(to: preserved)
        let sharedModel = store.models.appendingPathComponent("shared-model.keep")
        try Data("shared models must survive individual deletion".utf8).write(to: sharedModel)
        try await store.delete(removed)
        try await store.delete(removed) // retry is safe even after all files were already removed.
        try await store.save(removed) // a delayed editor write must not resurrect any result.
        let remaining = try await store.load()
        guard remaining.count == 1, remaining[0].id == keep.id,
              remaining[0].reference == keep.reference,
              !FileManager.default.fileExists(atPath: work.root.path),
              !FileManager.default.fileExists(atPath: (await store.audioURL(removed)).path),
              !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("Records/" + removed.id.uuidString + ".json").path),
              report.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }),
              FileManager.default.fileExists(atPath: preserved.path),
              FileManager.default.fileExists(atPath: sharedModel.path) else {
            throw BenchError("Individual deletion leaked results/work files, changed another recording, or removed shared models")
        }
        try await store.removeExport(report) // delayed share callback is safe after deletion.
        try store.temporaryFiles.remove(anotherWork.root)
        try FileManager.default.removeItem(at: sharedModel)
    }
}
