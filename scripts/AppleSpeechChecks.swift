import AVFoundation
import Foundation
import VoiceBenchCore

@main
struct AppleSpeechChecks {
    static func main() async {
        do { try await checks() }
        catch { fputs("FAIL: \(String(reflecting: error))\n", stderr); exit(1) }
    }

    static func fixture(_ url: URL, frames: Int, format: AVAudioFormat) throws {
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        guard frames > 0 else { return }
        let floats = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                   channels: format.channelCount, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: floats, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.03)) * 0.1 }
        }
        try file.write(from: buffer)
    }

    static func checks() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBenchSpeechChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Match the observed Int16 input's 141,973 frames / 2,709-frame tail, plus exact EOF boundaries.
        for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
            for interleaved in [false, true] {
                let format = AVAudioFormat(commonFormat: common, sampleRate: 16000, channels: 1, interleaved: interleaved)!
                for frames in [1, 4096, 8192, 141973] {
                    let url = base.appendingPathComponent(UUID().uuidString + ".caf")
                    try fixture(url, frames: frames, format: format)
                    let reader = try PCMFileReader(url: url, format: format, cancellation: CancellationFlag())
                    var offset: Int64 = 0
                    var buffers: [AVAudioPCMBuffer] = []
                    while let chunk = try await reader.next() {
                        guard chunk.startFrame == offset, chunk.sampleRate == 16000,
                              Int(chunk.buffer.frameLength) == min(4096, frames - Int(offset)) else {
                            throw BenchError("PCM tail dropped, duplicated or mistimed")
                        }
                        if let previous = buffers.last, previous === chunk.buffer { throw BenchError("Reused an in-flight PCM buffer") }
                        buffers.append(chunk.buffer)
                        offset += Int64(chunk.buffer.frameLength)
                    }
                    let state = await reader.snapshot()
                    guard offset == frames, state["apple_read_frames"] == String(frames),
                          state["apple_input_eof"] == "true", try await reader.next() == nil else {
                        throw BenchError("EOF was not stable or input was truncated")
                    }
                    // Retain the first block through all subsequent reads; it must remain unchanged.
                    if common == .pcmFormatFloat32, let buffer = buffers.first {
                        guard abs(buffer.floatChannelData![0][0]) < 0.000001 else { throw BenchError("Earlier PCM buffer was mutated") }
                    }
                    await reader.close()
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        let int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let original = base.appendingPathComponent("source.wav")
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        try fixture(original, frames: 425919, format: sourceFormat)
        let converted = base.appendingPathComponent("converted.caf")
        try AudioFiles.convert(source: original, target: converted, format: int16, cancellation: CancellationFlag())
        let convertedReader = try PCMFileReader(url: converted, format: int16, cancellation: CancellationFlag())
        while try await convertedReader.next() != nil { }
        let convertedState = await convertedReader.snapshot()
        guard let read = convertedState["apple_read_frames"].flatMap(Int.init), abs(read - 141973) <= 2 else {
            throw BenchError("Int16 resampling lost audio")
        }
        await convertedReader.close()

        let empty = base.appendingPathComponent("empty.caf")
        try fixture(empty, frames: 0, format: int16)
        do {
            _ = try PCMFileReader(url: empty, format: int16, cancellation: CancellationFlag())
            throw BenchError("Accepted empty PCM")
        } catch { if error.localizedDescription == "Accepted empty PCM" { throw error } }
        let flag = CancellationFlag()
        let cancelled = try PCMFileReader(url: converted, format: int16, cancellation: flag)
        _ = try await cancelled.next()
        flag.cancel()
        do { _ = try await cancelled.next(); throw BenchError("Ignored cancellation between PCM blocks") }
        catch is CancellationError { }
        await cancelled.close()

        let diagnostics = AppleSpeechDiagnostics(runID: UUID())
        diagnostics.event("analyze_audio", metadata: convertedReader.metadata)
        diagnostics.record(convertedState)
        let underlying = NSError(domain: "Fixture.Audio", code: 7, userInfo: [NSLocalizedDescriptionKey: "fixture read failure"])
        let originalError = NSError(domain: "Fixture.Input", code: 0,
                                    userInfo: [NSUnderlyingErrorKey: underlying, "long_value": String(repeating: "x", count: 5000)])
        diagnostics.failure(CancellationError(), stage: "receive_results")
        diagnostics.failure(originalError, stage: "read_audio")
        let failure = diagnostics.wrappedFailure(CancellationError(), stage: "receive_results")
        guard failure.stage == "read_audio", failure.configuration["apple_error_domain"] == "Fixture.Input",
              failure.configuration["apple_error_underlying.domain"] == "Fixture.Audio",
              failure.configuration["apple_error_at_receive_results"] != nil,
              (failure.configuration["apple_error_user_info.long_value"]?.count ?? 9999) < 2100 else {
            throw BenchError("Diagnostics lost the original failure, underlying error or bounds")
        }
        var recording = Recording(name: "synthetic diagnostic fixture", fileName: "fixture.wav", sha256: "fixture",
                                  duration: 8.87, sampleRate: 48000, channels: 2)
        var run = Run(engine: .apple)
        run.status = .failed; run.error = failure.localizedDescription; run.configuration = failure.configuration
        recording.runs = [run]
        let data = try Report(recording: recording, environment: [:]).json()
        let decoded = try JSONDecoder.iso8601.decode(Report.self, from: data)
        guard decoded.recording.runs[0].configuration["apple_error_stage"] == "read_audio",
              decoded.recording.runs[0].configuration["apple_input_eof"] == "true" else {
            throw BenchError("Exported report lost Apple Speech diagnostics")
        }
        print("PASS: PCM Int16/Float32 tails, exact EOF, distinct buffers, real Int16 resampling, empty input, cancellation, underlying errors and diagnostic report export. SpeechAnalyzer/iOS not executed.")
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
}
