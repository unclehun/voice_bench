import Foundation
import AVFoundation
import VoiceBenchCore

@main
struct SenseVoiceSmoke {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw BenchError("Usage: sensevoice-smoke MODEL_FOLDER AUDIO_FILE REPORT_FILE") }
            let models = URL(fileURLWithPath: CommandLine.arguments[1])
            let audio = URL(fileURLWithPath: CommandLine.arguments[2])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let input = try AVAudioFile(forReading: audio)
            let engine = SenseVoiceEngine()
            let result = try await engine.transcribe(source: audio, models: models, language: "auto", lowMemory: false, cancellation: CancellationFlag()) { segment in
                print("Segment \(segment.id): \(segment.text)")
            }
            guard !result.text.isEmpty, !result.segments.isEmpty else { throw BenchError("No text returned for known speech sample") }
            var recording = Recording(name: "Official Chinese sample — macOS smoke test", fileName: audio.lastPathComponent,
                                      sha256: try AudioFiles.hash(audio), duration: Double(input.length) / input.processingFormat.sampleRate,
                                      sampleRate: input.processingFormat.sampleRate, channels: Int(input.processingFormat.channelCount))
            var run = Run(engine: .senseVoice)
            run.status = .completed; run.rawText = result.text; run.segments = result.segments
            run.preparationMS = result.preparationMS; run.transcriptionMS = result.transcriptionMS
            run.configuration = result.configuration
            recording.runs = [run]
            let report = Report(recording: recording, environment: ["platform": "macOS smoke test, NOT iPhone",
                "device": "M1 Pro / 16GB", "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "purpose": "Verify shared native inference code only; no iPhone performance or accuracy claim"])
            try report.json().write(to: reportURL)
            print("PASS: real SenseVoice inference on macOS. Report: \(reportURL.path)")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
