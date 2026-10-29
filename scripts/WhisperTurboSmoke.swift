import Foundation
import AVFoundation
import VoiceBenchCore

/// Optional real inference check; requires separately prepared macOS native libraries and weights.
@main
struct WhisperTurboSmoke {
    static func main() async {
        do {
            guard (4...6).contains(CommandLine.arguments.count) else { throw BenchError("Usage: whisper-turbo-smoke MODEL_FOLDER AUDIO_FILE REPORT_FILE [--require-retry] [--check-lifecycle]") }
            let options = Set(CommandLine.arguments.dropFirst(4))
            guard options.isSubset(of: ["--require-retry", "--check-lifecycle"]) else { throw BenchError("Unknown smoke-test option") }
            let models = URL(fileURLWithPath: CommandLine.arguments[1])
            let audio = URL(fileURLWithPath: CommandLine.arguments[2])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let temporary = AppTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchWhisperTurboSmoke-" + UUID().uuidString))
            try temporary.reset()
            defer { try? FileManager.default.removeItem(at: temporary.root) }
            let input = try AVAudioFile(forReading: audio)
            let duration = Double(input.length) / input.processingFormat.sampleRate
            let engine = WhisperTurboSpeechEngine()
            let cancelled = CancellationFlag(); cancelled.cancel()
            do {
                _ = try await engine.transcribe(source: audio, models: models, runID: UUID(), cancellation: cancelled, temporaryFiles: temporary) { _ in }
                throw BenchError("Pre-cancelled Whisper Turbo call did not fail")
            } catch let failure as WhisperTurboSpeechFailure {
                guard failure.stage == "check_models" else { throw failure }
            }
            let result = try await engine.transcribe(source: audio, models: models, runID: UUID(), cancellation: CancellationFlag(), temporaryFiles: temporary) { segment in
                print("Segment \(segment.id): \(segment.text)")
            }
            if options.contains("--require-retry") && result.configuration["whisper_turbo_budget_retry_count"] == "0" {
                throw BenchError("Fixture did not exercise Whisper's bounded output-budget retry")
            }
            guard !result.text.isEmpty, !result.segments.isEmpty,
                  result.configuration["whisper_turbo_text_decoder"] == WhisperByteTokens.version,
                  result.configuration["whisper_turbo_temporary_token_table_removed"] == "true",
                  result.segments.allSatisfy({ $0.startSeconds >= 0 && $0.endSeconds <= duration + 0.001 }),
                  try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty else {
                throw BenchError("Missing text, invalid region bounds, leaked temporary audio")
            }
            var recording = Recording(name: "Local audio — macOS Whisper Turbo smoke test", fileName: audio.lastPathComponent,
                sha256: try AudioFiles.hash(audio), duration: duration, sampleRate: input.processingFormat.sampleRate,
                channels: Int(input.processingFormat.channelCount))
            var run = Run(engine: .whisperTurbo)
            run.status = .completed; run.rawText = result.text; run.segments = result.segments
            run.preparationMS = result.preparationMS; run.transcriptionMS = result.transcriptionMS
            run.configuration = result.configuration
            recording.runs = [run]
            try Report(recording: recording, environment: ["platform": "macOS smoke test, NOT iPhone",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "purpose": "Verify the shared Whisper Turbo inference implementation only; no iPhone performance or accuracy claim"]).json().write(to: reportURL)
            if options.contains("--check-lifecycle") {
                try await checkLifecycle(engine: engine, source: audio, models: models, temporary: temporary)
            }
            print("PASS: actual Whisper Turbo inference, cancellation, region bounds and temporary cleanup. Report: \(reportURL.path)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }

    static func checkLifecycle(engine: WhisperTurboSpeechEngine, source: URL, models: URL, temporary: AppTemporaryFiles) async throws {
        let flag = CancellationFlag()
        do {
            _ = try await engine.transcribe(source: source, models: models, runID: UUID(), cancellation: flag,
                temporaryFiles: temporary) { _ in flag.cancel() }
            throw BenchError("Cancellation after a decoded segment did not stop Whisper")
        } catch let failure as WhisperTurboSpeechFailure {
            guard flag.isCancelled, failure.configuration["whisper_turbo_temporary_audio_removed"] == "true",
                  failure.configuration["whisper_turbo_temporary_token_table_removed"] == "true",
                  try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty else { throw failure }
        }
        let silence = try temporary.file(extension: "caf", prefix: "Silence-")
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let file = try AVAudioFile(forWriting: silence, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            buffer.frameLength = 16000
            for index in 0..<16000 { buffer.floatChannelData![0][index] = 0 }
            try file.write(from: buffer)
        }
        let output = try await engine.transcribe(source: silence, models: models, runID: UUID(), cancellation: CancellationFlag(),
            temporaryFiles: temporary) { _ in }
        try temporary.remove(silence)
        guard output.text.isEmpty, output.segments.isEmpty,
              try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty else {
            throw BenchError("Whisper hallucinated on silence or leaked derived audio")
        }
        print("PASS: cancellation after real decoding and VAD silence leave no derived audio")
    }
}
