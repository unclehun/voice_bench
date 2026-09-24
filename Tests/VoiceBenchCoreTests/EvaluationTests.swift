import XCTest
@testable import VoiceBenchCore

final class EvaluationTests: XCTestCase {
    func testCharacterErrors() {
        let value = Evaluation.cer(reference: "你好世界", hypothesis: "你号世")
        XCTAssertEqual(value.substitutions, 1)
        XCTAssertEqual(value.deletions, 1)
        XCTAssertEqual(value.rate, 0.5)
        XCTAssertEqual(Evaluation.cer(reference: "你", hypothesis: "你好啊").rate, 2)
    }
    func testNormalizationPreservesFacts() {
        XCTAssertEqual(Evaluation.cer(reference: "你好，ABC！", hypothesis: "你 好 abc").rate, 0)
        XCTAssertNotEqual(Evaluation.cer(reference: "一百", hypothesis: "100").rate, 0)
        XCTAssertNotEqual(Evaluation.cer(reference: "台湾", hypothesis: "臺灣").rate, 0)
        XCTAssertEqual(Evaluation.cer(reference: "🙂", hypothesis: "🙂").referenceCount, 1)
    }
    func testEmptyReferenceAndSilence() {
        let empty = Evaluation.cer(reference: "， ", hypothesis: "你好")
        XCTAssertNil(empty.rate)
        XCTAssertEqual(empty.insertions, 2)
        XCTAssertEqual(Evaluation.cer(reference: "你好", hypothesis: "").rate, 1)
    }
    func testChunksDoNotDropOrDuplicateText() {
        let text = String(repeating: "你好🙂。", count: 301)
        let chunks = Evaluation.chunks(text, size: 19)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 19 })
    }
    func testRiskyCorrectionsAreNotApplied() {
        XCTAssertFalse(Evaluation.correctionCanApply(original: "不是十月", proposed: "是十一月"))
        XCTAssertFalse(Evaluation.correctionCanApply(original: "你好", proposed: ""))
        XCTAssertTrue(Evaluation.correctionCanApply(original: "你好世界", proposed: "你好，世界。"))
    }
    func testDiffReconstructsBothVersions() {
        let original = "你好，今天不用付款。", revised = "您好，今天不用付款！"
        let edits = TextDiff.edits(from: original, to: revised)
        XCTAssertEqual(edits.filter { $0.kind != .added }.map(\.text).joined(), original)
        XCTAssertEqual(edits.filter { $0.kind != .removed }.map(\.text).joined(), revised)
    }
    func testInterruptedRecoveryAndReport() throws {
        var recording = Recording(name: "测试", fileName: "x.wav", sha256: "hash", duration: 10, sampleRate: 16000, channels: 1)
        recording.reference = "你好"
        var run = Run(engine: .apple)
        run.rawText = "你"
        recording.runs = [run]
        recording.recoverInterruptedRuns()
        XCTAssertEqual(recording.runs[0].status, .interrupted)
        var report = Report(recording: recording, environment: [:])
        XCTAssertNil(report.evaluation[0].rawCER)
        recording.runs[0].status = .completed
        recording.runs[0].transcriptionMS = 2000
        report = Report(recording: recording, environment: [:])
        XCTAssertEqual(report.evaluation[0].rtf, 0.2)
        XCTAssertEqual(report.evaluation[0].rawCER?.rate, 0.5)
        XCTAssertNil(report.evaluation[0].correctedCER)
        XCTAssertFalse(try report.json().isEmpty)
    }
}
