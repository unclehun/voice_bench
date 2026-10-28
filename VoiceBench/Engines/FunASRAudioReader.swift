import AVFoundation
import VoiceBenchCore

/// A single AVAudioFile read may be short without being EOF (including after a seek).
/// Retain every returned frame and continue until the requested interval is complete.
enum FunASRAudioReader {
    static func samples(file: AVAudioFile, start: Int64, end: Int64,
                        cancellation: CancellationFlag) throws -> [Float] {
        guard file.processingFormat.commonFormat == .pcmFormatFloat32,
              file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 16000,
              start >= 0, end > start, end <= file.length, end - start <= 32 * 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw BenchError("FunASR 音频区间无效或过长。")
        }
        file.framePosition = start
        return try read(file: file, frameCount: Int(end - start), buffer: buffer, cancellation: cancellation)
    }

    static func read(file: AVAudioFile, frameCount: Int, buffer: AVAudioPCMBuffer,
                     cancellation: CancellationFlag) throws -> [Float] {
        let start = file.framePosition
        guard frameCount > 0, frameCount <= 32 * 16000, start + Int64(frameCount) <= file.length,
              file.processingFormat.commonFormat == .pcmFormatFloat32,
              file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 16000,
              buffer.format.isEqual(file.processingFormat), buffer.frameCapacity > 0 else {
            throw BenchError("FunASR 音频读取格式或帧范围无效。")
        }
        var result: [Float] = []
        result.reserveCapacity(frameCount)
        while result.count < frameCount {
            try cancellation.check()
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int(buffer.frameCapacity), frameCount - result.count))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0, buffer.frameLength <= count,
                  file.framePosition == start + Int64(result.count) + Int64(buffer.frameLength),
                  let pointer = buffer.floatChannelData?[0] else {
                throw BenchError("FunASR 音频提前结束或帧位置异常：预期 \(frameCount) 帧，读到 \(result.count) 帧。")
            }
            result.append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
        }
        guard result.allSatisfy({ $0.isFinite }) else { throw BenchError("FunASR 音频包含无效采样。") }
        return result
    }
}
