import Foundation

public enum CorrectionDisposition: String, Codable, Sendable {
    case automatic, review, rejected
}

public enum CorrectionDecision: String, Codable, Sendable {
    case automatic, pending, accepted, kept, rejected
    public var isApplied: Bool { self == .automatic || self == .accepted }
    public var title: String {
        switch self {
        case .automatic: return "已自动应用"
        case .pending: return "待确认"
        case .accepted: return "已人工接受"
        case .kept: return "已保留原文"
        case .rejected: return "未采用"
        }
    }
}

/// A model suggestion is untrusted until its anchor and evidence have been checked locally.
public struct CorrectionProposal: Codable, Sendable {
    public var original: String
    public var replacement: String
    public var anchor: String
    public var kind: String
    public var evidence: String
    public var evidence_source: String
    public var support: String
    public var reason: String

    public init(original: String, replacement: String, anchor: String, kind: String,
                evidence: String, evidenceSource: String = "transcript", support: String = "clear", reason: String) {
        self.original = original; self.replacement = replacement; self.anchor = anchor; self.kind = kind
        self.evidence = evidence; self.evidence_source = evidenceSource; self.support = support; self.reason = reason
    }
}

public struct CorrectionChange: Codable, Identifiable, Sendable {
    public var id = UUID()
    /// Character offsets in the immutable block original, never offsets in a model rewrite.
    public var start: Int?
    public var end: Int?
    public var proposal: CorrectionProposal
    public var disposition: CorrectionDisposition
    public var decision: CorrectionDecision
    public var policyReason: String
    public var isFormatOnly: Bool {
        Evaluation.normalize(proposal.original) == Evaluation.normalize(proposal.replacement)
    }
}

public extension CorrectionBlock {
    /// Reconstruct from immutable source offsets so independently accepting edits cannot shift anchors.
    mutating func rebuild() {
        guard let changes else { return }
        applied = Self.render(original: original, changes: changes.filter { $0.decision.isApplied })
        proposed = Self.render(original: original, changes: changes.filter { $0.disposition != .rejected })
    }

    static func render(original: String, changes: [CorrectionChange]) -> String {
        displayEdits(original: original, changes: changes)
            .filter { $0.kind != .removed }.map(\.text).joined()
    }

    /// The same validated source ranges drive both plain text and inline review markup.
    /// Keep each replacement paired with its entire original, even if they share characters.
    static func displayEdits(original: String, changes: [CorrectionChange]) -> [TextEdit] {
        let source = Array(original)
        var cursor = 0, result: [TextEdit] = []
        for change in changes.sorted(by: { ($0.start ?? Int.max) < ($1.start ?? Int.max) }) {
            guard let start = change.start, let end = change.end, start >= cursor, end > start, end <= source.count,
                  String(source[start..<end]) == change.proposal.original else { continue }
            if start > cursor { result.append(TextEdit(kind: .unchanged, text: String(source[cursor..<start]))) }
            result.append(TextEdit(kind: .removed, text: change.proposal.original))
            if !change.proposal.replacement.isEmpty {
                result.append(TextEdit(kind: .added, text: change.proposal.replacement))
            }
            cursor = end
        }
        if cursor < source.count { result.append(TextEdit(kind: .unchanged, text: String(source[cursor...]))) }
        return result
    }
}

public extension Correction {
    /// Pending, kept and rejected suggestions leave the paragraph unchanged.
    /// Legacy results have no source ranges, so diff their saved blocks individually.
    var displayEdits: [TextEdit] {
        if let document {
            return CorrectionBlock.displayEdits(original: document.original, changes: document.changes.filter { $0.decision.isApplied })
        }
        guard !blocks.isEmpty else { return text.map { [TextEdit(kind: .unchanged, text: $0)] } ?? [] }
        return blocks.flatMap { block in
            if let changes = block.changes {
                return CorrectionBlock.displayEdits(original: block.original, changes: changes.filter { $0.decision.isApplied })
            }
            return TextDiff.edits(from: block.original, to: block.applied)
        }
    }

    var changes: [CorrectionChange] { document?.changes ?? blocks.flatMap { $0.changes ?? [] } }
    var usesWholeDocument: Bool { document != nil || policyVersion == SemanticCorrection.policyVersion }
    var appliedChangeCount: Int { changes.filter { $0.decision.isApplied && !$0.isFormatOnly }.count }
    var formatChangeCount: Int { changes.filter { $0.decision.isApplied && $0.isFormatOnly }.count }
    var pendingChangeCount: Int { changes.filter { $0.decision == .pending }.count }
    var rejectedChangeCount: Int { changes.filter { $0.decision == .rejected }.count }
    var completedBlockCount: Int { blocks.filter { $0.state == "completed" }.count }
    var canReview: Bool {
        [SemanticCorrection.policyVersion, "semantic-edits-v2"].contains(policyVersion ?? "") && status != "running"
    }

    var resultSummary: String {
        guard policyVersion != nil else { return "旧版纠错结果；重新运行可使用逐条采纳规则" }
        var parts: [String] = []
        if appliedChangeCount > 0 { parts.append("已应用 \(appliedChangeCount) 处") }
        if formatChangeCount > 0 { parts.append("格式调整 \(formatChangeCount) 处") }
        if pendingChangeCount > 0 { parts.append("待确认 \(pendingChangeCount) 处") }
        if rejectedChangeCount > 0 { parts.append("未采用 \(rejectedChangeCount) 处异常建议") }
        let kept = changes.filter { $0.decision == .kept }.count
        if kept > 0 { parts.append("已保留原文 \(kept) 处") }
        if formatChangeCount > 0 && appliedChangeCount == 0 && pendingChangeCount == 0 && rejectedChangeCount == 0 && kept == 0 {
            return "仅格式调整 · \(formatChangeCount) 处"
        }
        if parts.isEmpty {
            if usesWholeDocument {
                if status == "running" { return "正在结合全文理解与纠错" }
                if status == "completed" { return "全文校对完成，未发现可确认的修改" }
                if status == "partial" { return "全文建议尚未完整返回，原文保留" }
                return "全文纠错未完成，原文保留"
            }
            return completedBlockCount > 0 ? "未发现可确认的修改" : "暂无已完成的纠错片段"
        }
        return parts.joined(separator: " · ")
    }

    mutating func refreshText() {
        if let document {
            text = CorrectionBlock.render(original: document.original, changes: document.changes.filter { $0.decision.isApplied })
            return
        }
        for index in blocks.indices { blocks[index].rebuild() }
        text = completedBlockCount > 0 ? blocks.map(\.applied).joined() : nil
    }

    mutating func recoverInterruption() {
        guard status == "running" else { return }
        status = "interrupted"; error = "上次纠错未正常结束；已完成部分仍保留。"
        phase = nil
        if document != nil {
            error = "上次全文纠错中断，已保存的修改和原始文字保留。"
            refreshText()
            return
        }
        guard policyVersion != nil else { return }
        for index in blocks.indices where ["queued", "running"].contains(blocks[index].state ?? "") {
            blocks[index].state = "unprocessed"
            blocks[index].note = "上次纠错中断，此片段保留原文。"
        }
        refreshText()
    }

    mutating func review(changeID: UUID, accept: Bool) throws {
        guard canReview else { throw BenchError("请等待本次纠错结束；旧版建议需要重新纠错。") }
        if let document {
            guard let index = document.changes.firstIndex(where: { $0.id == changeID }) else {
                throw BenchError("该纠错建议已更新，请重新打开结果。")
            }
            try Self.validateReview(document.changes[index], original: document.original)
            self.document?.changes[index].decision = accept ? .accepted : .kept
            refreshText()
            return
        }
        for blockIndex in blocks.indices {
            guard let changeIndex = blocks[blockIndex].changes?.firstIndex(where: { $0.id == changeID }) else { continue }
            guard let change = blocks[blockIndex].changes?[changeIndex] else { continue }
            try Self.validateReview(change, original: blocks[blockIndex].original)
            blocks[blockIndex].changes?[changeIndex].decision = accept ? .accepted : .kept
            refreshText()
            return
        }
        throw BenchError("该纠错建议已更新，请重新打开结果。")
    }

    private static func validateReview(_ change: CorrectionChange, original: String) throws {
        guard change.disposition != .rejected,
              let start = change.start, let end = change.end, start >= 0, end > start, end <= original.count,
              String(Array(original)[start..<end]) == change.proposal.original else {
            throw BenchError("该建议未通过位置或内容检查，不能采用。")
        }
    }
}
