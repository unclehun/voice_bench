import AVFoundation
import VoiceBenchCore

/// A buffer has one owner after it leaves the reader and must never be reused or mutated.
struct PCMFileChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let startFrame: AVAudioFramePosition
    let sampleRate: Int32
}

/// Pull-based reading keeps the app's input queue bounded and never reads past a known PCM EOF.
actor PCMFileReader {
    private var file: AVAudioFile?
    private let cancellation: CancellationFlag
    private let totalFrames: AVAudioFramePosition
    private let firstFrame: AVAudioFramePosition
    let startSeconds: Double
    let endSeconds: Double
    private let sampleRate: Int32
    private var position: AVAudioFramePosition = 0
    private var chunks = 0
    private var lastChunkFrames: AVAudioFrameCount = 0
    private var reachedEOF = false
    let metadata: [String: String]

    init(url: URL, format: AVAudioFormat, cancellation: CancellationFlag,
         startSeconds: Double = 0, endSeconds: Double? = nil,
         inspect: @Sendable ([String: String]) -> Void = { _ in }) throws {
        let input = try AVAudioFile(forReading: url, commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)
        let metadata = ["apple_file_format": Self.describe(input.fileFormat),
                        "apple_processing_format": Self.describe(input.processingFormat),
                        "apple_total_frames": String(input.length),
                        "apple_audio_seconds": String(Double(input.length) / input.processingFormat.sampleRate),
                        "apple_chunk_capacity_frames": "4096"]
        inspect(metadata)
        guard input.processingFormat.isEqual(format) else {
            throw BenchError("派生音频读取格式与 Apple Speech 要求不一致。")
        }
        guard input.length > 0 else { throw BenchError("派生音频没有可供识别的帧。") }
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.sampleRate <= Double(Int32.max), format.sampleRate.rounded() == format.sampleRate else {
            throw BenchError("派生音频采样率无法用于精确的帧时间戳。")
        }
        let duration = Double(input.length) / format.sampleRate
        guard startSeconds.isFinite, startSeconds >= 0, startSeconds < duration,
              endSeconds == nil || (endSeconds!.isFinite && endSeconds! > startSeconds) else {
            throw BenchError("派生音频片段的时间范围无效。")
        }
        // The same shared boundary must map to the same frame in adjacent language regions.
        let first = AVAudioFramePosition((startSeconds * format.sampleRate).rounded())
        let last = min(input.length, AVAudioFramePosition((min(endSeconds ?? duration, duration) * format.sampleRate).rounded()))
        guard last > first else { throw BenchError("派生音频片段为空。") }
        input.framePosition = first
        self.file = input
        self.cancellation = cancellation
        self.totalFrames = last
        self.firstFrame = first
        self.position = first
        self.startSeconds = Double(first) / format.sampleRate
        self.endSeconds = Double(last) / format.sampleRate
        self.sampleRate = Int32(format.sampleRate)
        self.metadata = metadata.merging(["apple_range_first_frame": String(first), "apple_range_end_frame": String(last)]) { _, new in new }
    }

    func next() throws -> PCMFileChunk? {
        try Task.checkCancellation()
        try cancellation.check()
        guard let file else { throw BenchError("音频读取器已关闭。") }
        guard position < totalFrames else {
            reachedEOF = true
            return nil
        }
        let count = AVAudioFrameCount(min(4096, totalFrames - position))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw BenchError("无法分配 Apple Speech 音频块。")
        }
        let start = position
        // EOF is determined above. In particular, never issue one more read after a partial tail.
        do { try file.read(into: buffer, frameCount: count) }
        catch { position = file.framePosition; throw error }
        position = file.framePosition
        guard buffer.frameLength > 0, position - start == Int64(buffer.frameLength), position <= totalFrames else {
            throw BenchError("派生音频提前结束或帧位置异常（\(position)/\(totalFrames)，本块 \(buffer.frameLength) 帧）。")
        }
        chunks += 1
        lastChunkFrames = buffer.frameLength
        return PCMFileChunk(buffer: buffer, startFrame: start - firstFrame, sampleRate: sampleRate)
    }

    func snapshot() -> [String: String] {
        ["apple_read_frames": String(position - firstFrame), "apple_input_chunks": String(chunks),
         "apple_last_chunk_frames": String(lastChunkFrames), "apple_input_eof": String(reachedEOF)]
    }

    func close() { file = nil }

    static func describe(_ format: AVAudioFormat) -> String {
        let stream = format.streamDescription.pointee
        return "rate=\(format.sampleRate),channels=\(format.channelCount),pcm=\(format.commonFormat.rawValue)," +
            "interleaved=\(format.isInterleaved),bytes_per_frame=\(stream.mBytesPerFrame)," +
            "format_id=\(stream.mFormatID),flags=\(stream.mFormatFlags)"
    }
}
