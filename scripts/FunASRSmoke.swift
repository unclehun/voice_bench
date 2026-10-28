import Foundation
import AVFoundation
import VoiceBenchCore

/// Optional real inference check; requires separately prepared macOS native libraries and weights.
@main
struct FunASRSmoke {
    static func main() async {
        do {
            guard (4...5).contains(CommandLine.arguments.count) else { throw BenchError("Usage: funASR-smoke MODEL_FOLDER AUDIO_FILE REPORT_FILE [--require-retry]") }
            let models = URL(fileURLWithPath: CommandLine.arguments[1])
            let audio = URL(fileURLWithPath: CommandLine.arguments[2])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let temporary = AppTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchFunASRSmoke-" + UUID().uuidString))
            try temporary.reset()
            defer { try? FileManager.default.removeItem(at: temporary.root) }
            let input = try AVAudioFile(forReading: audio)
            let duration = Double(input.length) / input.processingFormat.sampleRate
            let engine = FunASRSpeechEngine()
            let cancelled = CancellationFlag(); cancelled.cancel()
            do {
                _ = try await engine.transcribe(source: audio, models: models, runID: UUID(), cancellation: cancelled, temporaryFiles: temporary) { _ in }
                throw BenchError("Pre-cancelled FunASR call did not fail")
            } catch let failure as FunASRSpeechFailure {
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
            let trace = result.configuration["funasr_mlt_context_attempts_json"] ?? "[]"
            let attempts = try JSONDecoder().decode([[String: String]].self, from: Data(trace.utf8))
            let accepted = attempts.filter { $0["decision"] == "accepted" }
            guard accepted.count == result.segments.count else { throw BenchError("Speculative text was published or accepted text lost") }
            for (item, segment) in zip(accepted, result.segments) {
                guard let prefill = Int(item["prefill_upper_bound"] ?? ""), let generated = Int(item["generated_tokens"] ?? ""),
                      prefill + generated <= 512 - 16,
                      Int64((segment.startSeconds * 16000).rounded()) == Int64(item["start_frame"] ?? ""),
                      Int64((segment.endSeconds * 16000).rounded()) == Int64(item["end_frame"] ?? "") else {
                    throw BenchError("Accepted native output violated the context margin or frame ownership")
                }
            }
            for parent in attempts where parent["decision"]?.hasSuffix("_retry") == true {
                let lo = Int64(parent["start_frame"]!)!, hi = Int64(parent["end_frame"]!)!
                var cursor = lo
                for child in accepted {
                    let start = Int64(child["start_frame"]!)!, end = Int64(child["end_frame"]!)!
                    if start >= lo && end <= hi {
                        guard start == cursor else { throw BenchError("Retry dropped or duplicated audio") }
                        cursor = end
                    }
                }
                guard cursor == hi else { throw BenchError("Retry did not cover the complete parent audio") }
            }
            if CommandLine.arguments.count == 5 {
                guard CommandLine.arguments[4] == "--require-retry", Int(result.configuration["funasr_mlt_retry_count"] ?? "0")! > 0 else {
                    throw BenchError("Stress sample did not exercise native retry")
                }
            }
            var recording = Recording(name: "Official speech sample — macOS FunASR smoke test", fileName: audio.lastPathComponent,
                sha256: try AudioFiles.hash(audio), duration: duration, sampleRate: input.processingFormat.sampleRate,
                channels: Int(input.processingFormat.channelCount))
            var run = Run(engine: .funASR)
            run.status = .completed; run.rawText = result.text; run.segments = result.segments
            run.preparationMS = result.preparationMS; run.transcriptionMS = result.transcriptionMS
            run.configuration = result.configuration
            recording.runs = [run]
            try Report(recording: recording, environment: ["platform": "macOS smoke test, NOT iPhone",
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "purpose": "Verify the shared FunASR inference implementation only; no iPhone performance or accuracy claim"]).json().write(to: reportURL)
            print("PASS: actual FunASR inference, cancellation, region bounds and temporary cleanup. Report: \(reportURL.path)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
