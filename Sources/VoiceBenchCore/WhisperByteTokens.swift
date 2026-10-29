import Foundation

/// Whisper BPE pieces contain bytes, and an individual piece need not be valid UTF-8.
/// sherpa-onnx 1.13.8 sanitizes each piece before joining it. Carry the original
/// base64 spelling through that path as ASCII, then join bytes before decoding,
/// as OpenAI's tokenizer does. Token IDs and inference weights remain unchanged.
public enum WhisperByteTokens {
    public static let version = "base64-ascii-join-bytes-v1"

    public static func transportTable(from source: Data) throws -> Data {
        guard let text = String(data: source, encoding: .utf8) else { throw BenchError("Whisper 词表不是有效 UTF-8。") }
        var ids = Set<Int>()
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let id = Int(fields[1]), id >= 0, ids.insert(id).inserted else {
                throw BenchError("Whisper 词表格式或 token ID 无效。")
            }
            let payload = String(fields[0])
            _ = try bytes(from: payload)
            // Native ApplyBase64Decode removes this outer layer. The inner layer
            // stays ASCII and survives its per-token RemoveInvalidUtf8Sequences.
            lines.append("\(Data(payload.utf8).base64EncodedString()) \(id)")
        }
        guard !lines.isEmpty else { throw BenchError("Whisper 词表为空。") }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func text(from transportedTokens: [String]) throws -> String {
        var joined = Data()
        for payload in transportedTokens { joined.append(try bytes(from: payload)) }
        // Like tiktoken.decode(errors="replace"), decode the completed byte stream
        // once. Never discard an incomplete UTF-8 prefix/suffix inside a BPE token.
        return String(decoding: joined, as: UTF8.self)
    }

    private static func bytes(from payload: String) throws -> Data {
        // The pinned sherpa vocabulary spells its empty final text token as "=".
        if payload == "=" { return Data() }
        guard !payload.isEmpty, let bytes = Data(base64Encoded: payload) else {
            throw BenchError("Whisper token 不是有效 Base64，无法安全恢复文字。")
        }
        return bytes
    }
}
