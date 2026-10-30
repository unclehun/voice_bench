import AVFoundation
import VoiceBenchCore

enum FunASRAudioChecks {
    static func run(base: URL) throws {
        let url = base.appendingPathComponent("funasr-exact-frames.caf")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        func expected(_ frame: Int) -> Float { Float(frame % 8191) / 8192 }
        do {
            var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 89472)!
            buffer.frameLength = 89472
            for i in 0..<89472 { buffer.floatChannelData![0][i] = expected(i) }
            try output.write(from: buffer)
        }
        let input = try AVAudioFile(forReading: url)
        for (lo, hi) in [(8672, 89472), (0, 1), (6401, 16003), (88111, 89472), (0, 89472)] {
            let sharedValues = try AudioFiles.samples(file: input, start: Int64(lo), end: Int64(hi))
            guard sharedValues.count == hi - lo,
                  sharedValues.enumerated().allSatisfy({ $0.element == expected($0.offset + lo) }) else {
                throw BenchError("Shared audio reader lost or shifted PCM frames after seek")
            }
            let values = try FunASRAudioReader.samples(file: input, start: Int64(lo), end: Int64(hi), cancellation: CancellationFlag())
            guard values.count == hi - lo,
                  values.enumerated().allSatisfy({ $0.element == expected($0.offset + lo) }) else {
                throw BenchError("FunASR short-read/seek lost, duplicated or shifted PCM frames")
            }
        }
        let flag = CancellationFlag(); flag.cancel()
        do {
            _ = try FunASRAudioReader.samples(file: input, start: 0, end: 89472, cancellation: flag)
            throw BenchError("FunASR cancelled reader returned audio")
        } catch is CancellationError { }
        for (lo, hi) in [(-1, 100), (4, 4), (0, 89473)] {
            var rejected = false
            do { _ = try FunASRAudioReader.samples(file: input, start: Int64(lo), end: Int64(hi), cancellation: CancellationFlag()) }
            catch { rejected = true }
            guard rejected else { throw BenchError("FunASR reader accepted an invalid region") }
        }
        print("PASS: FunASR exact PCM samples across seeks, partial reads/tails, invalid ranges and cancellation")
    }
}
