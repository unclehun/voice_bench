import SwiftUI
import VoiceBenchCore

struct CorrectionResultsView: View {
    let run: Run
    var showDetails: Bool
    var reviewEnabled: Bool
    var review: ((UUID, Bool) -> Void)?
    @State private var detailsExpanded: Bool

    init(run: Run, showDetails: Bool = false, reviewEnabled: Bool = false,
         review: ((UUID, Bool) -> Void)? = nil) {
        self.run = run
        self.showDetails = showDetails
        self.reviewEnabled = reviewEnabled
        self.review = review
        _detailsExpanded = State(initialValue: showDetails)
    }

    private var correction: Correction { run.deepSeekResult }

    private var color: Color {
        if correction.status == "failed" { return .red }
        if correction.pendingChangeCount > 0 || correction.rejectedChangeCount > 0 || correction.status == "partial" { return .orange }
        if correction.appliedChangeCount > 0 { return .green }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label("DeepSeek Flash 公网纠错", systemImage: "cloud")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if correction.status == "running" { ProgressView().controlSize(.small) }
                Text(correction.statusTitle).font(.caption).foregroundStyle(color)
            }
            Text("\(correction.model) · \(BenchFormat.seconds(correction.elapsedMS))")
                .font(.caption2).foregroundStyle(.secondary)
            if !["not_requested", "skipped_empty", "skipped_unconfigured"].contains(correction.status) {
                Text(correction.resultSummary).font(.subheadline.weight(.medium)).foregroundStyle(color)
            }
            if correction.hasResult || (correction.document != nil && correction.status != "running"), let text = correction.text {
                Text(correction.usesWholeDocument ? (correction.hasResult ? "纠错后全文" : "保留原文（全文纠错未完成）") : "纠错后段落（历史结果）")
                    .font(.caption).foregroundStyle(.secondary)
                let edits = correction.displayEdits
                if edits.contains(where: { $0.kind != .unchanged }) {
                    Text("红色删除线：修改前 · 绿色：修改后").font(.caption2).foregroundStyle(.secondary)
                }
                ExpandableTranscript(text: text, edits: edits)
            }
            if correction.status == "running" {
                Text(correction.phase == "validating" ? "正在核对全文修改的位置与依据…" :
                     correction.phase == "retrying" ? "正在重新请求全文纠错…" : "正在通读全文，结合上下文生成整篇修改建议…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !correction.usesWholeDocument && correction.policyVersion != nil {
                Text("这是历史分段纠错结果；重新纠错将使用全文理解与纠错。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = correction.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !correction.changes.isEmpty {
                DisclosureGroup("查看修改与建议（\(correction.changes.count)）", isExpanded: $detailsExpanded) {
                    ForEach(correction.changes) { change in changeView(change) }
                }
                .font(.subheadline)
            }
            let failures = correction.blocks.filter { $0.state == "failed" || $0.state == "unprocessed" || !$0.note.isEmpty }
            if !correction.usesWholeDocument && !failures.isEmpty {
                DisclosureGroup("旧版片段处理说明（\(failures.count)）") {
                    ForEach(failures) { block in
                        Text("片段 \(block.id+1)：\(block.note)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if correction.policyVersion == nil, showDetails {
                ForEach(correction.blocks.filter { $0.proposed != nil && $0.original != $0.proposed }) { block in
                    DisclosureGroup("旧版片段 \(block.id+1) 的建议") {
                        if let proposed = block.proposed { diff(original: block.original, revised: proposed).font(.caption) }
                        Text(block.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("correction.result.deepSeek")
    }

    private func changeView(_ change: CorrectionChange) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(change.decision.title).font(.caption.weight(.semibold))
                    .foregroundStyle(change.decision == .pending ? Color.orange : change.decision.isApplied ? Color.green : Color.secondary)
                if change.isFormatOnly { Text("格式调整").font(.caption2).foregroundStyle(.secondary) }
            }
            diff(original: change.proposal.original, revised: change.proposal.replacement)
                .font(.subheadline).textSelection(.enabled)
            Text(change.policyReason).font(.caption).foregroundStyle(.secondary)
            if !change.proposal.evidence.isEmpty {
                Text("语境引用：\(change.proposal.evidence)").font(.caption).foregroundStyle(.secondary)
            }
            if !change.proposal.reason.isEmpty {
                Text("模型依据：\(change.proposal.reason)").font(.caption).foregroundStyle(.secondary)
            }
            if correction.canReview, review != nil, change.disposition != .rejected {
                HStack(spacing: 16) {
                    // Keep both controls in place as the decision changes so review rows
                    // do not lose/recreate the tapped button or change their layout.
                    Button(change.decision.isApplied ? "已采用修改" : "接受此修改") { review?(change.id, true) }
                        .disabled(change.decision.isApplied)
                        .tint(.blue).accessibilityIdentifier("correction.accept.\(change.id)")
                    Button(change.decision == .kept ? "已保留原文" : change.decision.isApplied ? "撤销修改" : "保留原文") {
                        review?(change.id, false)
                    }
                    .disabled(change.decision == .kept)
                    .tint(.secondary).accessibilityIdentifier("correction.keep.\(change.id)")
                }
                .font(.caption).buttonStyle(.bordered).disabled(!reviewEnabled)
            }
            Divider()
        }
        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diff(original: String, revised: String) -> Text {
        TextDiff.edits(from: original, to: revised).reduce(Text("")) { text, edit in
            switch edit.kind {
            case .unchanged: return text + Text(edit.text)
            case .removed: return text + Text(edit.text).foregroundColor(.red).strikethrough()
            case .added: return text + Text(edit.text).foregroundColor(.green).bold()
            }
        }
    }
}
