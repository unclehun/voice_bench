import Foundation
import AVFoundation
import VoiceBenchCore

/// Optional real inference check; requires separately prepared macOS native libraries and weights.
@main
struct QwenSmoke {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw BenchError("Usage: qwen-smoke MODEL_FOLDER AUDIO_FILE REPORT_FILE") }
            let models = URL(fileURLWithPath: CommandLine.arguments[1])
            let audio = URL(fileURLWithPath: CommandLine.arguments[2])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let temporary = AppTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchQwenSmoke-" + UUID().uuidString))
            try temporary.reset()
            defer { try? FileManager.default.removeItem(at: temporary.root) }
            let input = try AVAudioFile(forReading: audio)
            let duration = Double(input.length) / input.processingFormat.sampleRate
            let engine = QwenSpeechEngine()
            let cancelled = CancellationFlag(); cancelled.cancel()
            do {
                _ = try await engine.transcribe(source: audio, models: models, runID: UUID(), cancellation: cancelled, temporaryFiles: temporary) { _ in }
                throw BenchError("Pre-cancelled Qwen call did not fail")
            } catch let failure as QwenSpeechFailure {
                guard failure.stage == "check_models" else { throw failure }
            }
            let result = try await engine.transcribe(source: audio, models: models, runID: UUID(), cancellation: CancellationFlag(), temporaryFiles: temporary) { segment in
                print("Segment \(segment.id): \(segment.text)")
            }
            guard !result.text.isEmpty, !result.segments.isEmpty,
                  result.segments.allSatisfy({ $0.startSeconds >= 0 && $0.endSeconds <= duration + 0.001 && $0.language == nil }),
                  try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty else {
                throw BenchError("Missing text, invalid region bounds, fabricated language labels or leaked temporary audio")
            }
            var recording = Recording(name: "Official speech sample — macOS Qwen smoke test", fileName: audio.lastPathComponent,
                sha256: try AudioFiles.hash(audio), duration: duration, sampleRate: input.processingFormat.sampleRate,
                channels: Int(input.processingFormat.channelCount))
            var run = Run(engine: .qwen)
            run.status = .completed; run.rawText = result.text; run.segments = result.segments
            run.preparationMS = result.preparationMS; run.transcriptionMS = result.transcriptionMS
            run.configuration = result.configuration
            recording.runs = [run]
            try Report(recording: recording, environment: ["platform": "macOS smoke test, NOT iPhone",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "purpose": "Verify the shared Qwen inference implementation only; no iPhone performance or accuracy claim"]).json().write(to: reportURL)
            print("PASS: actual Qwen inference, cancellation, region bounds and temporary cleanup. Report: \(reportURL.path)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
