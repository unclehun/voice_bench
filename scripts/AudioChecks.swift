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
        let store = try LocalStore(baseURL: base.appendingPathComponent("Store"),
                                  modelManifestURL: URL(fileURLWithPath: "config/model-manifest.json"))
        fputs("Audio check: import and persist\n", stderr)
        var item = try await store.importAudio(source)
        guard item.sha256 == hash, item.channels == 2 else { throw BenchError("Import metadata") }
        item.reference = "新版"; item.revision = 2
        try await store.save(item)
        var stale = item; stale.reference = "旧版"; stale.revision = 1
        try await store.save(stale)
        let loaded = try await store.load()
        guard loaded.count == 1, loaded[0].reference == "新版" else { throw BenchError("Stale save overwrote newer data") }
        do {
            fputs("Audio check: reject missing model\n", stderr)
            _ = try await store.importModels(base)
            throw BenchError("Accepted incomplete model folder")
        } catch { guard !(error is BenchError) || error.localizedDescription != "Accepted incomplete model folder" else { throw error } }
        if CommandLine.arguments.count > 1 {
            fputs("Audio check: import full pinned model directory\n", stderr)
            let folder = URL(fileURLWithPath: CommandLine.arguments[1])
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
        try await store.delete(item)
        try await store.save(stale)
        fputs("Audio check: deletion\n", stderr)
        guard try await store.load().isEmpty else { throw BenchError("Delete failed") }
        print("PASS: real AVAudioConverter resampling, cancellation, hashing, audio import, revision ordering, model rejection and deletion. No microphone or ASR test performed.")
    }
}
