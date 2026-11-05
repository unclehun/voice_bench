import XCTest
@testable import VoiceBenchCore

final class RecognitionRemovalTests: XCTestCase {
    func testOnlyAppleAndQwenRemainAndRetiredDirectoriesAreScheduledForDeletion() {
        XCTAssertEqual(Set(EngineID.allCases.map(\.rawValue)), ["apple_speechtranscriber", "qwen3_asr_0_6b_weight_only4"])
        XCTAssertTrue(RetiredDataCleanup.internalDirectories.contains("Models"))
        XCTAssertTrue(RetiredDataCleanup.sourceDirectories.contains("SenseVoiceSmall_INT8"))
        XCTAssertFalse(RetiredDataCleanup.internalDirectories.contains("QwenWeightOnlyModels"))
        XCTAssertFalse(RetiredDataCleanup.sourceDirectories.contains(QwenASRModel.defaultDirectoryName))
    }

    func testMigrationRemovesEveryRetiredRunIncludingCorrectionAndLogs() throws {
        var record = Recording(name: "迁移测试", fileName: "original.wav", sha256: "hash", duration: 1, sampleRate: 16000, channels: 1)
        record.reference = "人工参考稿"; record.context = "确认背景"
        record.runs = EngineID.allCases.map { engine in
            var run = Run(engine: engine); run.status = .completed; run.rawText = "保留原文"
            var correction = DeepSeekTextCorrector.initialCorrection()
            correction.status = "completed"; correction.document = CorrectionDocument(original: run.rawText, isComplete: true)
            correction.refreshText(); run.deepSeekCorrection = correction
            run.recordDeepSeekLog(DeepSeekRequestLog(operationID: UUID(), attempt: 1, endpoint: "endpoint", requestBody: "保留日志"))
            return run
        }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        let originalRuns = object["runs"] as! [[String: Any]]
        var retired = originalRuns[0]
        retired["id"] = UUID().uuidString; retired["engine"] = "sensevoice_small_int8"
        retired["rawText"] = "retired-source-marker"
        retired["deepSeekCorrection"] = ["text": "retired-correction-marker"]
        retired["deepSeekRequestLogs"] = [["responseBody": "retired-log-marker"]]
        object["runs"] = [retired, originalRuns[0], retired, originalRuns[1]]
        let migrated = try XCTUnwrap(RetiredDataCleanup.cleanRecording(JSONSerialization.data(withJSONObject: object)))
        let result = try JSONSerialization.jsonObject(with: migrated) as! [String: Any]
        let runs = result["runs"] as! [[String: Any]]
        XCTAssertEqual(runs.count, 2)
        for (actual, expected) in zip(runs, originalRuns) {
            XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected))
        }
        XCTAssertFalse(String(decoding: migrated, as: UTF8.self).contains("retired-"))
        let decoded = try JSONDecoder().decode(Recording.self, from: migrated)
        XCTAssertEqual(decoded.fileName, record.fileName)
        XCTAssertEqual(decoded.reference, record.reference)
        XCTAssertEqual(decoded.context, record.context)
        XCTAssertEqual(decoded.runs.count, 2)
        let again = try RetiredDataCleanup.cleanRecording(migrated)
        XCTAssertNil(again)
        let exported = Report(recording: decoded, environment: [:]).markdown()
        XCTAssertFalse(exported.contains("SenseVoice"))
        XCTAssertTrue(exported.contains("Apple Speech"))
        XCTAssertTrue(exported.contains("Qwen3-ASR"))
    }
}
