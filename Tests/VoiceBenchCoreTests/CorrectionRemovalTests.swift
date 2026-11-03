import XCTest
@testable import VoiceBenchCore

final class CorrectionRemovalTests: XCTestCase {
    func testUpgradeDeletesRetiredCorrectionFromEveryRunButPreservesDeepSeek() throws {
        var object = try fixture()
        var runs = object["runs"] as! [[String: Any]]
        let retainedResults = runs.map { $0["deepSeekCorrection"] as! [String: Any] }
        for i in runs.indices {
            let document: [String: Any] = ["original": "retired-source-copy", "changes": [["decision": "accepted"]]]
            let retired: [String: Any] = ["model": "Apple Foundation Models/system-managed", "text": "retired-history-marker",
                                         "document": document, "error": "retired-error", "blocks": [["note": "retired-note"]]]
            runs[i]["correction"] = retired
            runs[i]["configuration"] = ["apple_locale": "zh_CN", "apple_correction_model": "old",
                                        "apple_text_correction_prompt": "old", "foundation_models_state": "old",
                                        "deepseek_correction_mode": "whole-document", "apple_stage": "completed"]
        }
        object["runs"] = runs
        let cleaned = try XCTUnwrap(RetiredDataCleanup.cleanRecording(JSONSerialization.data(withJSONObject: object)))
        let result = try JSONSerialization.jsonObject(with: cleaned) as! [String: Any]
        let retained = result["runs"] as! [[String: Any]]
        XCTAssertEqual(retained.count, EngineID.allCases.count)
        XCTAssertEqual(result["revision"] as? Int, 13)
        for (i, run) in retained.enumerated() {
            XCTAssertNil(run["correction"])
            XCTAssertEqual(run["rawText"] as? String, runs[i]["rawText"] as? String)
            XCTAssertEqual(run["engine"] as? String, runs[i]["engine"] as? String)
            XCTAssertTrue(NSDictionary(dictionary: run["deepSeekCorrection"] as! [String: Any]).isEqual(to: retainedResults[i]))
            let config = run["configuration"] as! [String: String]
            XCTAssertEqual(config["apple_locale"], "zh_CN")
            XCTAssertEqual(config["apple_stage"], "completed")
            XCTAssertEqual(config["deepseek_correction_mode"], "whole-document")
            XCTAssertNil(config["apple_correction_model"])
            XCTAssertNil(config["apple_text_correction_prompt"])
            XCTAssertNil(config["foundation_models_state"])
        }
        XCTAssertEqual(result["reference"] as? String, "人工参考稿")
        XCTAssertEqual(result["context"] as? String, "已确认背景")
        XCTAssertEqual(result["fileName"] as? String, "original.wav")
        XCTAssertFalse(String(decoding: cleaned, as: UTF8.self).contains("retired-history-marker"))
        let secondPass = try RetiredDataCleanup.cleanRecording(cleaned)
        XCTAssertNil(secondPass)
        let recording = try JSONDecoder().decode(Recording.self, from: cleaned)
        XCTAssertTrue(recording.runs.contains { $0.engine == .apple })
        XCTAssertTrue(recording.runs.allSatisfy { $0.deepSeekResult.changes.first?.decision == .accepted })
    }

    func testRemovedDataCannotBeReencodedEvenWhenDecoderSeesOldKeys() throws {
        var object = try fixture()
        var runs = object["runs"] as! [[String: Any]]
        runs[0]["correction"] = ["text": "retired-history-marker", "model": "Apple Foundation Models/system-managed"]
        object["runs"] = runs
        let record = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: object))
        let saved = try JSONEncoder().encode(record)
        let persisted = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        for run in persisted["runs"] as! [[String: Any]] { XCTAssertNil(run["correction"]) }
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("retired-history-marker"))
    }

    func testLocalOnlyHistoryDoesNotBecomeDeepSeekOrLeavePhantomResult() throws {
        var object = try fixture()
        var runs = object["runs"] as! [[String: Any]]
        for i in runs.indices {
            runs[i].removeValue(forKey: "deepSeekCorrection")
            // Malformed retired data must be removable without decoding its former type.
            runs[i]["correction"] = "retired malformed object"
        }
        object["runs"] = runs
        let cleaned = try XCTUnwrap(RetiredDataCleanup.cleanRecording(JSONSerialization.data(withJSONObject: object)))
        let record = try JSONDecoder().decode(Recording.self, from: cleaned)
        XCTAssertTrue(record.runs.allSatisfy { $0.deepSeekCorrection == nil && !$0.hasCorrectionAttempts })
        XCTAssertFalse(record.hasCorrectionResults)
        XCTAssertFalse(record.hasCorrectionAttempts)
    }

    func testReportsContainOnlyDeepSeekMetricsAndKeepSpeechRecognition() throws {
        let record = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: fixture()))
        let report = Report(recording: record, environment: [:])
        let data = try report.json()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["schemaVersion"] as? Int, 5)
        for evaluation in object["evaluation"] as! [[String: Any]] {
            XCTAssertNil(evaluation["correctedCER"])
            XCTAssertNil(evaluation["deltaCER"])
            XCTAssertTrue(evaluation.keys.contains("deepSeekCER"))
            XCTAssertTrue(evaluation.keys.contains("deepSeekDeltaCER"))
        }
        let exported = (object["recording"] as! [String: Any])["runs"] as! [[String: Any]]
        XCTAssertTrue(exported.allSatisfy { $0["correction"] == nil && $0["deepSeekCorrection"] != nil })
        let markdown = report.markdown()
        XCTAssertFalse(markdown.contains("Apple 纠错"))
        XCTAssertFalse(markdown.contains("本地纠错"))
        XCTAssertTrue(markdown.contains("Apple Speech"))
        XCTAssertTrue(markdown.contains("DeepSeek 纠错 CER"))
    }

    func testMigratedReviewDecisionsAndIDsStillWork() throws {
        let record = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: fixture()))
        var restored = record.runs[0].deepSeekResult
        let change = try XCTUnwrap(restored.changes.first)
        XCTAssertEqual(restored.text, "九次")
        try restored.review(changeID: change.id, accept: false)
        XCTAssertEqual(restored.text, "十次")
        try restored.review(changeID: change.id, accept: true)
        XCTAssertEqual(restored.text, "九次")
    }

    func testInterruptedRecoveryTouchesOnlyRemainingCorrection() throws {
        var record = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: fixture()))
        record.runs[0].deepSeekCorrection?.status = "running"
        record.recoverInterruptedRuns()
        XCTAssertEqual(record.runs[0].deepSeekCorrection?.status, "interrupted")
        XCTAssertTrue(record.runs.contains { $0.engine == .apple })
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        XCTAssertTrue((encoded["runs"] as! [[String: Any]]).allSatisfy { $0["correction"] == nil })
    }

    private func fixture() throws -> [String: Any] {
        let proposal = CorrectionProposal(original: "十", replacement: "九", anchor: "十次", kind: "number", evidence: "十次", reason: "待用户确认")
        let change = CorrectionChange(start: 0, end: 1, proposal: proposal, disposition: .review, decision: .accepted, policyReason: "用户确认")
        var correction = DeepSeekTextCorrector.initialCorrection()
        correction.status = "completed"
        correction.document = CorrectionDocument(original: "十次", changes: [change], isComplete: true)
        correction.refreshText()
        var record = Recording(name: "测试录音", fileName: "original.wav", sha256: "original-hash", duration: 1, sampleRate: 16000, channels: 1)
        record.revision = 12; record.reference = "人工参考稿"; record.context = "已确认背景"
        record.runs = EngineID.allCases.map { engine in
            var run = Run(engine: engine)
            run.status = .completed; run.rawText = "十次"; run.deepSeekCorrection = correction
            return run
        }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
    }
}
