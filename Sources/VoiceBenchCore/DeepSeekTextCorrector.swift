import Foundation
import CryptoKit

/// Sends one full ASR transcript and user context. Audio, references and other ASR outputs never enter this interface.
public actor DeepSeekTextCorrector {
    public static let model = "deepseek-flash"
    public static let modelDisplayName = "DeepSeek-V4.1-Flash-1017"
    public static let promptVersion = SemanticCorrection.promptVersion
    public static let instructions = SemanticCorrection.instructions
    static let endpoint = URL(string: "https://api.deepseek.com/beta/chat/completions")!
    static let toolName = "submit_document_corrections"

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 150
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public static func initialCorrection(context: String = "") -> Correction {
        var value = Correction()
        value.model = model
        value.promptVersion = promptVersion
        value.promptHash = SHA256.hash(data: Data(instructions.utf8)).map { String(format: "%02x", $0) }.joined()
        value.context = context
        value.policyVersion = SemanticCorrection.policyVersion
        return value
    }

    public static func normalizedAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw BenchError("请输入有效的 DeepSeek API Key，不能包含空格或换行。")
        }
        return key
    }

    public func correct(original: String, context: String, apiKey: String?, cancellation: CancellationFlag,
                        progress: @escaping @Sendable (Correction) async -> Void) async -> Correction {
        var output = Self.initialCorrection(context: context)
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output.status = "skipped_empty"; return output
        }
        guard let apiKey, let key = try? Self.normalizedAPIKey(apiKey) else {
            output.status = "skipped_unconfigured"
            output.error = "请先在设置中保存 DeepSeek API Key，再进行全文纠错。"
            return output
        }
        return await CorrectionWorkflow.run(original: original, context: context, initial: output,
            cancellation: cancellation, respond: { input in try await self.request(input, apiKey: key) },
            message: { Self.safeMessage($0) },
            retryable: { $0 is ResponseFailure || $0 is BenchError }, progress: progress)
    }

    /// All required fields, including nested objects, are enforced by the official strict tool schema.
    static func requestBody(_ input: SemanticCorrection.Input) throws -> Data {
        let keys = ["original", "replacement", "anchor", "kind", "evidence", "evidence_source", "support", "reason"]
        var properties: [String: [String: Any]] = Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "string"]) })
        properties["evidence_source"] = ["type": "string", "enum": ["transcript", "background"]]
        properties["support"] = ["type": "string", "enum": ["clear", "ambiguous", "knowledge_only"]]
        let editSchema: [String: Any] = ["type": "object", "additionalProperties": false, "properties": properties, "required": keys]
        let fields: [String: Any] = ["edits": ["type": "array", "items": editSchema] as [String: Any], "has_more": ["type": "boolean"]]
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["edits", "has_more"],
            "properties": fields
        ]
        let function: [String: Any] = ["name": toolName, "strict": true,
            "description": "Return all corrections for the complete document in one response.", "parameters": schema]
        let tool: [String: Any] = ["type": "function", "function": function]
        let choice: [String: Any] = ["type": "function", "function": ["name": toolName]]
        let body: [String: Any] = [
            "model": model, "thinking": ["type": "disabled"], "temperature": 0,
            "max_tokens": 32768, "stream": false,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": try input.json()]],
            "tools": [tool], "tool_choice": choice
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable { let name: String; let arguments: String }
                    let type: String
                    let function: Function
                }
                let tool_calls: [ToolCall]?
            }
            let message: Message
            let finish_reason: String?
        }
        let id: String?
        let choices: [Choice]
    }
    private struct ResponseFailure: Error { let message: String }
    private struct HTTPFailure: Error { let status: Int; let contextLimit: Bool }

    private func request(_ input: SemanticCorrection.Input, apiKey: String) async throws -> SemanticCorrection.Response {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(input)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BenchError("DeepSeek 返回了无效的网络响应。") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = (object?["error"] as? [String: Any])?["code"] as? String
            throw HTTPFailure(status: http.statusCode, contextLimit: code == "context_length_exceeded")
        }
        return try Self.decodeResponse(data)
    }

    static func decodeResponse(_ data: Data) throws -> SemanticCorrection.Response {
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ResponseFailure(message: decodingMessage(error, stage: "API 响应")) }
        // Only expose validated UUID request IDs, never arbitrary remote values or error bodies.
        let requestID = envelope.id.flatMap(UUID.init(uuidString:)).map { "（响应 ID：\($0.uuidString)）" } ?? ""
        guard envelope.choices.count == 1, let choice = envelope.choices.first else {
            throw ResponseFailure(message: "DeepSeek 全文纠错返回了异常的结果数量。" + requestID)
        }
        guard choice.finish_reason == "tool_calls" else {
            let reason = choice.finish_reason == "length" ? "输出被截断" : "未返回完整的结构化纠错结果"
            throw ResponseFailure(message: "DeepSeek 全文纠错\(reason)，原文保留。" + requestID)
        }
        guard let calls = choice.message.tool_calls, calls.count == 1, let call = calls.first,
              call.type == "function", call.function.name == toolName else {
            throw ResponseFailure(message: "DeepSeek 未返回预期的全文纠错工具结果，原文保留。" + requestID)
        }
        let arguments = call.function.arguments
        guard !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ResponseFailure(message: "DeepSeek 全文纠错返回空白内容，原文保留。" + requestID)
        }
        do { return try JSONDecoder().decode(SemanticCorrection.Response.self, from: Data(arguments.utf8)) }
        catch { throw ResponseFailure(message: decodingMessage(error, stage: "纠错对象") + requestID) }
    }

    private static func decodingMessage(_ error: Error, stage: String) -> String {
        func path(_ context: DecodingError.Context, key: String? = nil) -> String {
            (context.codingPath.map(\.stringValue) + (key.map { [$0] } ?? [])).joined(separator: ".")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "DeepSeek \(stage)缺少字段 \(path(context, key: key.stringValue))，原文保留。"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "DeepSeek \(stage)字段类型无效：\(path(context))，原文保留。"
        default: return "DeepSeek \(stage) JSON 无效，原文保留。"
        }
    }

    static func safeMessage(_ error: Error) -> String {
        if let error = error as? BenchError { return error.message }
        if let failure = error as? ResponseFailure { return failure.message }
        if let failure = error as? HTTPFailure {
            if failure.contextLimit { return "全文超出 DeepSeek 当前模型的上下文容量，未拆分或截断原文。" }
            switch failure.status {
            case 401: return "DeepSeek API Key 无效，请在设置中更新。"
            case 402: return "DeepSeek 账户余额不足，请到开放平台检查。"
            case 403: return "DeepSeek 拒绝访问，请检查 API Key 权限。"
            case 429: return "DeepSeek 请求过于频繁，请稍后手动重试。"
            case 500...599: return "DeepSeek 服务暂不可用（HTTP \(failure.status)），请稍后重试。"
            default: return "DeepSeek 请求失败（HTTP \(failure.status)）；未生成全文纠错结果，原文保留。"
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "DeepSeek 全文请求超时，原文保留，请稍后重试。"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "无法连接 DeepSeek，原文保留，请检查互联网连接。"
            default: break
            }
        }
        return "DeepSeek 全文请求失败，原文保留，请稍后重试。"
    }
}
