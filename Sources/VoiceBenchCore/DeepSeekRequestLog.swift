import Foundation

/// A durable, credential-free trace of one HTTP attempt, separate from the adopted correction.
public struct DeepSeekRequestLog: Codable, Identifiable, Sendable {
    public var id = UUID()
    public let operationID: UUID
    public let attempt: Int
    public let startedAt: Date
    public let endpoint: String
    public let requestBody: String
    public var state = "started"
    public var completedAt: Date?
    public var elapsedMS: Double?
    public var httpStatus: Int?
    public var responseHeaders: [String: String]?
    public var responseBody: String?
    public var responseByteCount: Int?
    public var responseWasUTF8: Bool?
    public var responseID: String?
    public var responseModel: String?
    public var finishReason: String?
    public var toolName: String?
    public var arguments: String?
    public var normalization: String?
    public var error: String?
    public var errorDomain: String?
    public var errorCode: Int?

    public init(operationID: UUID, attempt: Int, endpoint: String, requestBody: String) {
        self.operationID = operationID; self.attempt = attempt
        self.startedAt = Date()
        self.endpoint = endpoint; self.requestBody = requestBody
    }

    public var stateTitle: String {
        switch state {
        case "started": return "请求已发起"
        case "received": return "已收到响应"
        case "succeeded": return "解析成功"
        case "failed": return "失败"
        default: return state
        }
    }

    public var formatted: String {
        var lines = ["DeepSeek 请求日志", "日志 ID：\(id)", "操作 ID：\(operationID)",
                     "本次操作第 \(attempt) 次尝试", "开始时间：\(ISO8601DateFormatter().string(from: startedAt))",
                     "状态：\(stateTitle)", "接口：\(endpoint)", "HTTP：\(httpStatus.map(String.init) ?? "未收到")",
                     "响应 ID：\(responseID ?? "无")", "模型：\(responseModel ?? "未返回")",
                     "finish_reason：\(finishReason ?? "无")", "工具：\(toolName ?? "无")"]
        if let normalization { lines += ["结构兼容处理：\(normalization)"] }
        if let elapsedMS { lines.append(String(format: "耗时：%.0f ms", elapsedMS)) }
        if let error { lines += ["错误：\(error)"] }
        if let errorDomain, let errorCode { lines += ["错误域／代码：\(errorDomain) / \(errorCode)"] }
        lines += ["", "--- 请求正文（不含鉴权头） ---", requestBody]
        if let responseHeaders {
            lines += ["", "--- 响应头（允许的诊断字段） ---"]
            lines += responseHeaders.keys.sorted().map { "\($0): \(responseHeaders[$0]!)" }
        }
        lines += ["", "--- HTTP 响应原文 ---", responseBody ?? "尚未收到 UTF-8 响应"]
        if responseWasUTF8 == false { lines += ["响应不是有效 UTF-8，无法解码的字节以替换字符显示。"] }
        if let arguments { lines += ["", "--- 工具 arguments 原文 ---", arguments] }
        return lines.joined(separator: "\n")
    }

    /// The API key never enters a trace, including when a remote body echoes it back.
    static func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty else { return text }
        // content and arguments are themselves JSON strings inside the HTTP JSON envelope.
        var variants = Set<String>()
        var variant = secret
        for _ in 0..<4 {
            variants.insert(variant)
            guard let encoded = try? JSONEncoder().encode(variant) else { break }
            variant = String(String(decoding: encoded, as: UTF8.self).dropFirst().dropLast())
        }
        var result = text
        for value in variants.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: value, with: "[REDACTED]")
        }
        return result
    }
}

public extension Run {
    /// Keep the most recent 20 HTTP attempts, across manual reruns as well as automatic retries.
    mutating func recordDeepSeekLog(_ log: DeepSeekRequestLog) {
        var logs = deepSeekRequestLogs ?? []
        if let index = logs.firstIndex(where: { $0.id == log.id }) { logs[index] = log }
        else { logs.append(log) }
        deepSeekRequestLogs = Array(logs.suffix(20))
    }
}
