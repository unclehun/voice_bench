import AVFoundation
import CryptoKit
import VoiceBenchCore

enum AudioFiles {
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bounded-memory decode/resample. The entire source is never expanded in RAM.
    static func convert(source: URL, target: URL, format: AVAudioFormat, cancellation: CancellationFlag) throws {
        try cancellation.check()
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) }
        catch { throw BenchError("无法打开源音频：\(error.localizedDescription)") }
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw BenchError("无法创建音频格式转换器。")
        }
        var settings = format.settings
        // File storage is interleaved; the converter's in-memory buffers may be planar.
        settings[AVLinearPCMIsNonInterleaved] = false
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: target) } }
        let destination: AVAudioFile
        do {
            destination = try AVAudioFile(forWriting: target, settings: settings,
                                          commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch { throw BenchError("无法创建派生音频：\(error.localizedDescription)") }
        var readError: Error?
        var exhausted = false
        while true {
            try cancellation.check()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { count, inputStatus in
                if exhausted || input.framePosition >= input.length || cancellation.isCancelled {
                    exhausted = true; inputStatus.pointee = .endOfStream; return nil
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: max(1, min(count, 8192))) else {
                    readError = BenchError("无法分配音频缓冲区。")
                    inputStatus.pointee = .endOfStream; return nil
                }
                do {
                    try input.read(into: buffer)
                    if buffer.frameLength == 0 { exhausted = true; inputStatus.pointee = .endOfStream; return nil }
                    inputStatus.pointee = .haveData
                    return buffer
                } catch {
                    readError = BenchError("读取音频帧失败（\(input.framePosition)/\(input.length)）：\(error.localizedDescription)")
                    inputStatus.pointee = .endOfStream; return nil
                }
            }
            // Do not coalesce Error? with NSError?: implicit bridging can manufacture nilError.
            if let readError { throw readError }
            if let conversionError { throw BenchError("重采样失败：\(conversionError.localizedDescription)") }
            if output.frameLength > 0 {
                do { try destination.write(from: output) }
                catch { throw BenchError("写入派生音频失败：\(error.localizedDescription)") }
            }
            switch status {
            case .endOfStream: try cancellation.check(); complete = true; return
            case .error: throw BenchError("音频解码或重采样失败。")
            case .haveData, .inputRanDry: break
            @unknown default: throw BenchError("未知音频转换状态。")
            }
        }
    }

    static func samples(file: AVAudioFile, start: Int64, end: Int64) throws -> [Float] {
        let count = max(0, min(end, file.length) - max(0, start))
        guard count > 0, count <= 32 * 16000,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)) else {
            throw BenchError("语音分段为空或超过内存保护上限。")
        }
        file.framePosition = max(0, start)
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let pointer = buffer.floatChannelData?[0] else { throw BenchError("需要 Float32 单声道音频。") }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
    }
}
