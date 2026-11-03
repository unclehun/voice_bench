import XCTest
@testable import VoiceBenchCore

final class WholeDocumentCorrectionTests: XCTestCase {
    func testLongDocumentSentExactlyOnceWithoutWindowsOrSummaries() async throws {
        let original = String(repeating: "开头与结尾的事实必须同时理解。\n", count: 2000) + "结尾保留。"
        let calls = InputCapture()
        let correction = await run(original) { input in
            await calls.append(input)
            return .init()
        }
        let inputs = await calls.values
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.document, original)
        XCTAssertEqual(correction.document?.original, original)
        XCTAssertEqual(correction.text, original)
        XCTAssertTrue(correction.blocks.isEmpty)
        XCTAssertEqual(correction.status, "completed")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(inputs[0])) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["document", "background"])
    }

    func testFarAwayEvidenceAndRepeatedWordsUseWholeSourceOffsets() async throws {
        let original = "这里有龙具。\n" + String(repeating: "无关的日常叙述。", count: 150) + "后来便放下龙具，天天等着同样的好事发生。"
        let proposal = CorrectionProposal(original: "龙具", replacement: "农具", anchor: "后来便放下龙具",
            kind: "lexical", evidence: "天天等着同样的好事发生", reason: "守株待兔的耕作语境支持同音词农具。")
        var correction = await run(original) { _ in .init(edits: [proposal]) }
        XCTAssertEqual(correction.changes.count, 1)
        let change = try XCTUnwrap(correction.changes.first)
        XCTAssertTrue((change.start ?? 0) > 1000)
        try correction.review(changeID: change.id, accept: true)
        XCTAssertTrue(correction.text?.hasPrefix("这里有龙具。") == true)
        XCTAssertTrue(correction.text?.hasSuffix("后来便放下农具，天天等着同样的好事发生。") == true)
    }

    func testMoreThanEightSuggestionsAreReturnedTogether() async throws {
        let proposals = (0..<20).map { index in
            CorrectionProposal(original: "word\(index),", replacement: "word\(index)，", anchor: "word\(index),",
                kind: "format", evidence: "word\(index),", reason: "统一标点。")
        }
        let original = proposals.map(\.original).joined(separator: "\n")
        let correction = await run(original) { _ in .init(edits: proposals) }
        XCTAssertEqual(correction.status, "completed")
        XCTAssertEqual(correction.changes.count, 20)
        XCTAssertEqual(correction.formatChangeCount, 20)
        XCTAssertEqual(correction.text, proposals.map(\.replacement).joined(separator: "\n"))
    }

    func testRetryRepeatsEntireUnchangedDocumentAndBackground() async {
        let original = String(repeating: "完整原文。", count: 500)
        let calls = InputCapture()
        let correction = await run(original, context: "已确认的背景", retryable: { _ in true }) { input in
            await calls.append(input)
            if await calls.values.count == 1 { throw BenchError("模拟格式失败") }
            return .init()
        }
        let inputs = await calls.values
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.allSatisfy { $0.document == original && $0.background == "已确认的背景" })
        XCTAssertEqual(correction.attemptCount, 2)
        XCTAssertEqual(correction.status, "completed")
        XCTAssertNil(correction.error)
    }

    func testFailureRetainsFullOriginalAndDoesNotInventPartialSuccess() async {
        let original = "全文开头。\n正文与结尾。"
        let calls = InputCapture()
        let correction = await run(original, retryable: { _ in true }) { input in
            await calls.append(input)
            throw BenchError("返回缺少 has_more")
        }
        let inputs = await calls.values
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(correction.status, "failed")
        XCTAssertEqual(correction.text, original)
        XCTAssertEqual(correction.document?.isComplete, false)
        XCTAssertEqual(correction.error, "返回缺少 has_more")
        XCTAssertFalse(correction.hasResult)
        XCTAssertTrue(correction.changes.isEmpty)
        XCTAssertTrue(correction.resultSummary.contains("全文纠错未完成"))
        var recording = Recording(name: "失败测试", fileName: "test.wav", sha256: "test", duration: 1, sampleRate: 16000, channels: 1)
        var run = Run(engine: .qwen)
        run.rawText = original; run.status = .completed; run.deepSeekCorrection = correction
        recording.runs = [run]; recording.reference = original
        let report = Report(recording: recording, environment: [:])
        XCTAssertEqual(report.evaluation[0].rawCER?.rate, 0)
        XCTAssertNil(report.evaluation[0].deepSeekCER)
    }

    func testCancellationAfterGenerationCannotApplyEditsOrRetry() async {
        let flag = CancellationFlag()
        let calls = InputCapture()
        let correction = await run("你好,", cancellation: flag, retryable: { _ in true }) { input in
            await calls.append(input)
            flag.cancel()
            return .init(edits: [CorrectionProposal(original: ",", replacement: "，", anchor: "你好,", kind: "format", evidence: "你好,", reason: "标点")])
        }
        let inputs = await calls.values
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(correction.status, "cancelled")
        XCTAssertEqual(correction.text, "你好,")
        XCTAssertTrue(correction.changes.isEmpty)
    }

    func testIncompleteResponseIsExplicitAndIsNotSplitIntoMoreRequests() async {
        let calls = InputCapture()
        let correction = await run("完整原文") { input in
            await calls.append(input)
            return .init(hasMore: true)
        }
        let inputs = await calls.values
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(correction.status, "partial")
        XCTAssertEqual(correction.document?.isComplete, false)
        XCTAssertTrue(correction.error?.contains("未能返回全文所有建议") == true)
    }

    func testOversizedBackgroundAndEmptySourceDoNotInvokeModel() async {
        let calls = InputCapture()
        let respond: @Sendable (SemanticCorrection.Input) async throws -> SemanticCorrection.Response = { input in
            await calls.append(input); return .init()
        }
        let empty = await run(" \n", respond: respond)
        let invalid = await run("原文", context: String(repeating: "字", count: 1001), respond: respond)
        let inputs = await calls.values
        XCTAssertTrue(inputs.isEmpty)
        XCTAssertEqual(empty.status, "skipped_empty")
        XCTAssertEqual(invalid.status, "failed")
        XCTAssertEqual(invalid.text, "原文")
    }

    func testWholeDocumentReviewMarkupPersistenceAndCERUseAdoptedText() throws {
        let original = "👨‍👩‍👧‍👦请王小明来。\n后来王小明到了。"
        let proposals = [CorrectionProposal(original: "王小明", replacement: "王晓明", anchor: "请王小明来", kind: "proper_name", evidence: "王晓明", evidenceSource: "background", reason: "已确认姓名")]
        let changes = try SemanticCorrection.changes(original: original, background: "王晓明", suggestions: proposals)
        var correction = Correction()
        correction.policyVersion = SemanticCorrection.policyVersion
        correction.status = "completed"
        correction.document = CorrectionDocument(original: original, changes: changes, isComplete: true)
        try correction.review(changeID: changes[0].id, accept: true)
        XCTAssertEqual(correction.text, "👨‍👩‍👧‍👦请王晓明来。\n后来王小明到了。")
        XCTAssertEqual(correction.displayEdits.filter { $0.kind == .removed }.map(\.text), ["王小明"])
        XCTAssertEqual(correction.displayEdits.filter { $0.kind == .added }.map(\.text), ["王晓明"])
        XCTAssertEqual(correction.displayEdits.filter { $0.kind != .removed }.map(\.text).joined(), correction.text)
        var restored = try JSONDecoder().decode(Correction.self, from: JSONEncoder().encode(correction))
        XCTAssertEqual(restored.document?.changes[0].decision, .accepted)
        try restored.review(changeID: changes[0].id, accept: false)
        XCTAssertEqual(restored.text, original)
        XCTAssertTrue(restored.displayEdits.allSatisfy { $0.kind == .unchanged })

        var recording = Recording(name: "测试", fileName: "test.wav", sha256: "test", duration: 1, sampleRate: 16000, channels: 1)
        var run = Run(engine: .qwen)
        run.rawText = original; run.status = .completed; run.deepSeekCorrection = correction
        recording.runs = [run]; recording.reference = correction.text!
        let report = Report(recording: recording, environment: [:])
        XCTAssertEqual(report.evaluation[0].deepSeekCER?.rate, 0)
        XCTAssertTrue(report.markdown().contains("处理范围：完整原文"))
        let json = try JSONSerialization.jsonObject(with: report.json()) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 5)
    }

    func testOldSegmentedResultsRemainReviewableAndDoNotMigrateDecisions() throws {
        var correction = Correction()
        correction.policyVersion = "semantic-edits-v2"; correction.status = "completed"
        let proposal = CorrectionProposal(original: "十", replacement: "九", anchor: "十次", kind: "number", evidence: "十次", reason: "待确认")
        let change = CorrectionChange(start: 0, end: 1, proposal: proposal, disposition: .review, decision: .accepted, policyReason: "旧版")
        var block = CorrectionBlock(id: 0, original: "十次", proposed: nil, applied: "九次", note: "")
        block.changes = [change]; block.state = "completed"; correction.blocks = [block]
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(correction)) as! [String: Any]
        object.removeValue(forKey: "document"); object.removeValue(forKey: "attemptCount")
        var restored = try JSONDecoder().decode(Correction.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(restored.canReview)
        XCTAssertFalse(restored.usesWholeDocument)
        XCTAssertEqual(restored.changes[0].decision, .accepted)
        try restored.review(changeID: change.id, accept: false)
        XCTAssertEqual(restored.text, "十次")
    }

    func testInterruptedFullDocumentRestoresOriginalWithoutCreatingSegments() throws {
        var correction = Correction()
        correction.status = "running"; correction.phase = "document"
        correction.policyVersion = SemanticCorrection.policyVersion
        correction.document = CorrectionDocument(original: "完整原文")
        var restored = try JSONDecoder().decode(Correction.self, from: JSONEncoder().encode(correction))
        restored.recoverInterruption()
        XCTAssertEqual(restored.status, "interrupted")
        XCTAssertEqual(restored.text, "完整原文")
        XCTAssertTrue(restored.blocks.isEmpty)
    }

    private func run(_ original: String, context: String = "", cancellation: CancellationFlag = CancellationFlag(),
                     retryable: @escaping @Sendable (Error) -> Bool = { _ in false },
                     respond: @escaping @Sendable (SemanticCorrection.Input) async throws -> SemanticCorrection.Response) async -> Correction {
        await CorrectionWorkflow.run(original: original, context: context, initial: Correction(), cancellation: cancellation,
            respond: respond, message: { ($0 as? BenchError)?.message ?? "测试错误" }, retryable: retryable, progress: { _ in })
    }
}

private actor InputCapture {
    var values: [SemanticCorrection.Input] = []
    func append(_ input: SemanticCorrection.Input) { values.append(input) }
}
