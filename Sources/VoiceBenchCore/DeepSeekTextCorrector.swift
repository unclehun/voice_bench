import Foundation
import CryptoKit

/// Only accepts one ASR transcript and user-supplied context, never a reference or another engine's output.
public actor DeepSeekTextCorrector {
    // Official API alias, verified 2026-10-28: DeepSeek-V4.1-Flash-1017.
    // https://api-docs.deepseek.com/updates/
    public static let model = "deepseek-flash"
    public static let modelDisplayName = "DeepSeek-V4.1-Flash-1017"
    public static let promptVersion = SemanticCorrection.promptVersion
    public static let instructions = SemanticCorrection.instructions

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
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
            output.error = "请在设置中保存 DeepSeek API Key；Apple 本地纠错独立运行。"
            return output
        }
        return await CorrectionWorkflow.run(original: original, context: context, initial: output,
            documentLimit: 12000, cancellation: cancellation,
            respond: { input in try await self.request(input, apiKey: key) },
            message: { Self.safeMessage($0) },
            stopAfterError: { !($0 is ResponseFailure) && !($0 is BenchError) }, progress: progress)
    }

    private struct Message: Encodable { let role: String; let content: String }
    private struct Request: Encodable {
        let model = DeepSeekTextCorrector.model
        let messages: [Message]
        let thinking = ["type": "disabled"]
        let response_format = ["type": "json_object"]
        let temperature = 0
        let max_tokens = 4096
        let stream = false
    }
    private struct Envelope: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }
    private struct ResponseFailure: Error { let message: String; init(_ message: String) { self.message = message } }
    private struct HTTPFailure: Error { let status: Int }

    private func request(_ input: SemanticCorrection.Input, apiKey: String) async throws -> SemanticCorrection.Response {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let inputJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        request.httpBody = try JSONEncoder().encode(Request(messages: [
            Message(role: "system", content: Self.instructions), Message(role: "user", content: inputJSON)
        ]))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BenchError("DeepSeek 返回了无效的网络响应。") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPFailure(status: http.statusCode) }
        // Do not surface remote error bodies: they may contain user input or credentials.
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard let choice = envelope.choices.first, choice.finish_reason == "stop",
                  let content = choice.message.content, !content.isEmpty else {
                throw ResponseFailure("DeepSeek 未返回完整纠错结果（可能被截断或拒绝），保留原文。")
            }
            return try JSONDecoder().decode(SemanticCorrection.Response.self, from: Data(content.utf8))
        } catch let failure as ResponseFailure { throw failure }
        catch { throw ResponseFailure("DeepSeek 返回格式无效，保留原文。") }
    }

    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? BenchError { return error.message }
        if let failure = error as? ResponseFailure { return failure.message }
        if let failure = error as? HTTPFailure {
            switch failure.status {
            case 401: return "DeepSeek API Key 无效，请在设置中更新。"
            case 402: return "DeepSeek 账户余额不足，请到开放平台检查。"
            case 403: return "DeepSeek 拒绝访问，请检查 API Key 权限。"
            case 429: return "DeepSeek 请求过于频繁，请稍后手动重试。"
            case 500...599: return "DeepSeek 服务暂不可用（HTTP \(failure.status)），请稍后手动重试。"
            default: return "DeepSeek 请求失败（HTTP \(failure.status)）。"
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "DeepSeek 请求超时，请检查网络后手动重试。"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "无法连接 DeepSeek，请检查互联网连接。"
            default: break
            }
        }
        return "DeepSeek 网络请求失败，请稍后手动重试。"
    }
}
