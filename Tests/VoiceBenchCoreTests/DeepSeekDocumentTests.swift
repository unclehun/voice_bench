import XCTest
@testable import VoiceBenchCore

final class DeepSeekDocumentTests: XCTestCase {
    func testRequestUsesFullSourceAndStrictSchemaWithoutRoutingFields() throws {
        let original = String(repeating: "全文。", count: 5000)
        let data = try DeepSeekTextCorrector.requestBody(.init(document: original, background: "确认背景"))
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(body["response_format"])
        XCTAssertEqual(DeepSeekTextCorrector.endpoint.path, "/beta/chat/completions")
        let messages = body["messages"] as! [[String: String]]
        let input = try JSONDecoder().decode(SemanticCorrection.Input.self, from: Data(messages[1]["content"]!.utf8))
        XCTAssertEqual(input.document, original)
        XCTAssertEqual(input.background, "确认背景")
        let tools = body["tools"] as! [[String: Any]]
        let function = tools[0]["function"] as! [String: Any]
        XCTAssertEqual(function["strict"] as? Bool, true)
        XCTAssertEqual(function["name"] as? String, DeepSeekTextCorrector.toolName)
        let schema = function["parameters"] as! [String: Any]
        XCTAssertEqual(Set(schema["required"] as! [String]), ["edits", "has_more"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let properties = schema["properties"] as! [String: Any]
        let edits = properties["edits"] as! [String: Any]
        let item = edits["items"] as! [String: Any]
        XCTAssertEqual(item["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(item["required"] as! [String]), ["original", "replacement", "anchor", "kind", "evidence", "evidence_source", "support", "reason"])
        XCTAssertFalse(Set(properties.keys).contains("segment_id"))
        XCTAssertFalse(Set(properties.keys).contains("overview"))
    }

    func testStrictToolResponseDecodesWithoutContentIDsOrMode() throws {
        let result = try DeepSeekTextCorrector.decodeResponse(envelope("{\"edits\":[],\"has_more\":false}"))
        XCTAssertTrue(result.edits.isEmpty)
        XCTAssertFalse(result.has_more)
    }

    func testMissingFieldRecordsExactFieldAndResponseID() {
        do {
            _ = try DeepSeekTextCorrector.decodeResponse(envelope("{\"edits\":[]}"))
            XCTFail("Missing has_more must not be silently defaulted")
        } catch {
            let message = DeepSeekTextCorrector.safeMessage(error)
            XCTAssertTrue(message.contains("缺少字段 has_more"))
            XCTAssertTrue(message.contains("11111111-1111-1111-1111-111111111111"))
        }
    }

    func testMalformedJSONAndWhitespaceAreRejected() {
        for content in ["{\"edits\":[", " \n\t"] {
            XCTAssertThrowsError(try DeepSeekTextCorrector.decodeResponse(envelope(content)))
        }
    }

    func testTruncatedOrWrongToolResultsCannotBeAdopted() {
        let content = "{\"edits\":[],\"has_more\":false}"
        XCTAssertThrowsError(try DeepSeekTextCorrector.decodeResponse(envelope(content, finish: "length")))
        XCTAssertThrowsError(try DeepSeekTextCorrector.decodeResponse(envelope(content, tool: "other_function")))
        XCTAssertThrowsError(try DeepSeekTextCorrector.decodeResponse(envelope(content, count: 2)))
        XCTAssertThrowsError(try DeepSeekTextCorrector.decodeResponse(envelope(content, finish: "stop")))
    }

    func testActualClientRetriesBadArgumentsUsingSameWholeDocument() async throws {
        let state = StubState(replies: [
            (200, envelope("{\"edits\":[]}")),
            (200, envelope("{\"edits\":[],\"has_more\":false}"))
        ])
        let session = session(state)
        defer { session.invalidateAndCancel() }
        let client = DeepSeekTextCorrector(session: session)
        let original = String(repeating: "原文包含完整前后文。\n", count: 200)
        let result = await client.correct(original: original, context: "测试背景", apiKey: "test-key", cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertEqual(result.status, "completed")
        XCTAssertEqual(result.attemptCount, 2)
        XCTAssertEqual(state.requests.count, 2)
        for request in state.requests {
            XCTAssertEqual(request.url, DeepSeekTextCorrector.endpoint)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: String]]
            let input = try JSONDecoder().decode(SemanticCorrection.Input.self, from: Data(messages[1]["content"]!.utf8))
            XCTAssertEqual(input.document, original)
            XCTAssertEqual(input.background, "测试背景")
        }
        XCTAssertEqual(result.text, original)
        XCTAssertTrue(result.blocks.isEmpty)
    }

    func testAuthenticationFailureIsNotRetriedAndSourceIsRetained() async {
        let state = StubState(replies: [(401, Data("{\"error\":{\"message\":\"secret-body\"}}".utf8))])
        let session = session(state)
        defer { session.invalidateAndCancel() }
        let result = await DeepSeekTextCorrector(session: session).correct(original: "完整原文", context: "", apiKey: "test-key", cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.text, "完整原文")
        XCTAssertTrue(result.error?.contains("API Key 无效") == true)
        XCTAssertFalse(result.error?.contains("secret-body") == true)
    }

    func testContextLimitDoesNotFallBackToSplitting() async {
        let state = StubState(replies: [(400, Data("{\"error\":{\"code\":\"context_length_exceeded\"}}".utf8))])
        let session = session(state)
        defer { session.invalidateAndCancel() }
        let original = String(repeating: "原文", count: 10000)
        let result = await DeepSeekTextCorrector(session: session).correct(original: original, context: "", apiKey: "test-key", cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertEqual(state.requests.count, 1)
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.text, original)
        XCTAssertTrue(result.error?.contains("上下文容量") == true)
        XCTAssertTrue(result.blocks.isEmpty)
    }

    private func envelope(_ content: String, finish: String = "tool_calls", tool: String = DeepSeekTextCorrector.toolName, count: Int = 1) -> Data {
        let call: [String: Any] = ["type": "function", "function": ["name": tool, "arguments": content]]
        let message: [String: Any] = ["content": NSNull(), "tool_calls": Array(repeating: call, count: count)]
        let choice: [String: Any] = ["finish_reason": finish, "message": message]
        let response: [String: Any] = ["id": "11111111-1111-1111-1111-111111111111", "choices": [choice]]
        return try! JSONSerialization.data(withJSONObject: response)
    }

    private func session(_ state: StubState) -> URLSession {
        StubProtocol.state = state
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [(Int, Data)]
    private var storedRequests: [URLRequest] = []
    init(replies: [(Int, Data)]) { self.replies = replies }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    func next(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let index = storedRequests.count
        var captured = request
        // URLSession may expose an uploaded Data body as a stream to URLProtocol.
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        storedRequests.append(captured)
        return replies[min(index, replies.count - 1)]
    }
}

private final class StubProtocol: URLProtocol {
    static var state: StubState!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.state.next(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
