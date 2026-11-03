import XCTest
@testable import VoiceBenchCore

final class DeepSeekLogTests: XCTestCase {
    func testBoundedHistoryUpdatesOneAttemptWithoutDuplicatingEvents() throws {
        var run = Run(engine: .qwen)
        let operationID = UUID()
        var first = DeepSeekRequestLog(operationID: operationID, attempt: 1, endpoint: "https://api.deepseek.com/beta/chat/completions", requestBody: "{}")
        run.recordDeepSeekLog(first)
        first.state = "received"; first.responseBody = "raw first response"
        run.recordDeepSeekLog(first)
        first.state = "failed"; first.error = "缺少 edits"
        run.recordDeepSeekLog(first)
        XCTAssertEqual(run.deepSeekRequestLogs?.count, 1)
        XCTAssertEqual(run.deepSeekRequestLogs?.first?.responseBody, "raw first response")
        for _ in 0..<21 {
            run.recordDeepSeekLog(DeepSeekRequestLog(operationID: UUID(), attempt: 1, endpoint: "endpoint", requestBody: "{}"))
        }
        XCTAssertEqual(run.deepSeekRequestLogs?.count, 20)
        XCTAssertFalse(run.deepSeekRequestLogs!.contains { $0.id == first.id })
    }

    func testRequestLogAppearsInJSONExportWithoutAffectingCEROrAdoptedText() throws {
        var run = Run(engine: .qwen)
        run.rawText = "原文"; run.status = .completed
        var correction = DeepSeekTextCorrector.initialCorrection()
        correction.status = "completed"
        correction.document = CorrectionDocument(original: run.rawText, isComplete: true)
        correction.refreshText(); run.deepSeekCorrection = correction
        var log = DeepSeekRequestLog(operationID: UUID(), attempt: 1, endpoint: "endpoint", requestBody: "payload")
        log.responseBody = "raw response"; log.state = "succeeded"
        run.recordDeepSeekLog(log)
        var record = Recording(name: "测试", fileName: "test.wav", sha256: "hash", duration: 1, sampleRate: 16000, channels: 1)
        record.runs = [run]; record.reference = "原文"
        let report = Report(recording: record, environment: [:])
        let text = String(decoding: try report.json(), as: UTF8.self)
        XCTAssertTrue(text.contains("deepSeekRequestLogs"))
        XCTAssertTrue(text.contains("raw response"))
        XCTAssertEqual(report.evaluation[0].deepSeekCER?.rate, 0)
        XCTAssertEqual(run.deepSeekResult.text, "原文")
    }
}
