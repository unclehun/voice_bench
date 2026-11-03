import XCTest
@testable import VoiceBenchCore

final class CorrectionPresentationTests: XCTestCase {
    func testAcceptedReplacementShowsEntireOriginalImmediatelyBeforeReplacement() throws {
        let change = suggestion("王小明", "王晓明", start: 2)
        var correction = result([block("请让王小明来。", changes: [change])])
        XCTAssertEqual(correction.displayEdits, [edit(.unchanged, "请让王小明来。")])

        try correction.review(changeID: change.id, accept: true)

        XCTAssertEqual(correction.displayEdits, [edit(.unchanged, "请让"), edit(.removed, "王小明"),
                                               edit(.added, "王晓明"), edit(.unchanged, "来。")])
        XCTAssertEqual(correction.text, "请让王晓明来。")
        assertReconstructs(correction, original: "请让王小明来。")
    }

    func testOnlyAppliedDecisionsAreHighlighted() {
        let decisions: [CorrectionDecision] = [.automatic, .accepted, .pending, .kept, .rejected]
        for decision in decisions {
            let change = suggestion("十", "九", start: 2, decision: decision)
            let correction = result([block("录音十。", changes: [change])])
            XCTAssertEqual(correction.displayEdits.contains { $0.kind == .removed }, decision.isApplied)
            XCTAssertEqual(correction.text, decision.isApplied ? "录音九。" : "录音十。")
            assertReconstructs(correction, original: "录音十。")
        }
    }

    func testAcceptAndUndoPreserveOtherEditsAndParagraphBoundaries() throws {
        let first = suggestion("十", "九", start: 0)
        let second = suggestion("二", "两", start: 0, decision: .automatic)
        var correction = result([block("十次。\n", changes: [first]), block("二次。", changes: [second])])
        let original = "十次。\n二次。"

        try correction.review(changeID: first.id, accept: true)
        XCTAssertEqual(correction.text, "九次。\n两次。")
        assertReconstructs(correction, original: original)

        try correction.review(changeID: first.id, accept: false)
        XCTAssertEqual(correction.text, "十次。\n两次。")
        XCTAssertEqual(correction.displayEdits.filter { $0.kind == .removed }.map(\.text), ["二"])
        assertReconstructs(correction, original: original)

        try correction.review(changeID: first.id, accept: true)
        XCTAssertEqual(correction.text, "九次。\n两次。")
        assertReconstructs(correction, original: original)
    }

    func testSourceOffsetsHandleEmojiRepeatedWordsAndDifferentReplacementLengths() {
        let correction = result([block("👨‍👩‍👧‍👦王小明和王小明。", changes: [
            suggestion("王小明", "小王", start: 5, decision: .accepted),
            suggestion("王小明", "王晓明同学", start: 1, decision: .accepted)
        ])])
        XCTAssertEqual(correction.text, "👨‍👩‍👧‍👦王晓明同学和小王。")
        XCTAssertEqual(correction.displayEdits, [edit(.unchanged, "👨‍👩‍👧‍👦"), edit(.removed, "王小明"),
            edit(.added, "王晓明同学"), edit(.unchanged, "和"), edit(.removed, "王小明"),
            edit(.added, "小王"), edit(.unchanged, "。")])
        assertReconstructs(correction, original: "👨‍👩‍👧‍👦王小明和王小明。")
    }

    func testInvalidAndOverlappingRangesCannotProduceMisleadingMarkup() {
        let correction = result([block("甲乙丙丁", changes: [
            suggestion("甲乙", "一", start: 0, decision: .accepted),
            suggestion("乙丙", "二", start: 1, decision: .accepted),
            suggestion("错", "三", start: 3, decision: .accepted),
            suggestion("甲", "四", start: -1, decision: .accepted),
            suggestion("丁", "五", start: 99, decision: .accepted)
        ])])
        XCTAssertEqual(correction.text, "一丙丁")
        XCTAssertEqual(correction.displayEdits, [edit(.removed, "甲乙"), edit(.added, "一"), edit(.unchanged, "丙丁")])
        assertReconstructs(correction, original: "甲乙丙丁")
    }

    func testAutomaticFormatChangeAndDeletionRetainOriginalInMarkup() {
        let correction = result([block("你好,嗯世界", changes: [
            suggestion(",", "，", start: 2, decision: .automatic),
            suggestion("嗯", "", start: 3, decision: .accepted)
        ])])
        XCTAssertEqual(correction.text, "你好，世界")
        XCTAssertEqual(correction.displayEdits, [edit(.unchanged, "你好"), edit(.removed, ","),
            edit(.added, "，"), edit(.removed, "嗯"), edit(.unchanged, "世界")])
        assertReconstructs(correction, original: "你好,嗯世界")
    }

    func testReviewSurvivesPersistenceWithoutAddingMarkupToAdoptedText() throws {
        let change = suggestion("十", "九", start: 2)
        var correction = result([block("录音十", changes: [change])])
        try correction.review(changeID: change.id, accept: true)
        let saved = try JSONDecoder().decode(Correction.self, from: JSONEncoder().encode(correction))
        XCTAssertEqual(saved.text, "录音九")
        XCTAssertEqual(saved.changes.first?.id, change.id)
        XCTAssertEqual(saved.changes.first?.decision, .accepted)
        XCTAssertEqual(saved.displayEdits, correction.displayEdits)
    }

    func testLegacyBlocksAndTextOnlyResultsRemainReadable() {
        var legacy = Correction()
        legacy.status = "completed"
        legacy.text = "录音九"
        legacy.blocks = [CorrectionBlock(id: 0, original: "录音十", proposed: "录音九", applied: "录音九", note: "")]
        assertReconstructs(legacy, original: "录音十")
        XCTAssertTrue(legacy.displayEdits.contains { $0.kind == .removed })
        legacy.blocks = []
        XCTAssertEqual(legacy.displayEdits, [edit(.unchanged, "录音九")])
    }

    private func suggestion(_ original: String, _ replacement: String, start: Int,
                            decision: CorrectionDecision = .pending) -> CorrectionChange {
        CorrectionChange(start: start, end: start + original.count,
            proposal: CorrectionProposal(original: original, replacement: replacement, anchor: original,
                kind: "word", evidence: original, reason: "测试"),
            disposition: decision == .rejected ? .rejected : .review, decision: decision, policyReason: "测试")
    }

    private func block(_ original: String, changes: [CorrectionChange]) -> CorrectionBlock {
        var block = CorrectionBlock(id: 0, original: original, proposed: nil, applied: original, note: "")
        block.changes = changes
        block.state = "completed"
        return block
    }

    private func result(_ blocks: [CorrectionBlock]) -> Correction {
        var correction = Correction()
        correction.status = "completed"
        correction.policyVersion = SemanticCorrection.policyVersion
        correction.blocks = blocks.enumerated().map { index, value in
            var block = value
            block.id = index
            return block
        }
        correction.refreshText()
        return correction
    }

    private func edit(_ kind: TextEdit.Kind, _ text: String) -> TextEdit { TextEdit(kind: kind, text: text) }

    private func assertReconstructs(_ correction: Correction, original: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(correction.displayEdits.filter { $0.kind != .added }.map(\.text).joined(), original, file: file, line: line)
        XCTAssertEqual(correction.displayEdits.filter { $0.kind != .removed }.map(\.text).joined(), correction.text, file: file, line: line)
    }
}
