import SwiftUI
import VoiceBenchCore

struct CorrectionResultsView: View {
    let run: Run
    var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(CorrectionProvider.allCases) { provider in
                CorrectionResultView(provider: provider, correction: run.correction(for: provider), showDetails: showDetails)
            }
        }
    }
}

private struct CorrectionResultView: View {
    let provider: CorrectionProvider
    let correction: Correction
    let showDetails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(provider.title, systemImage: provider == .apple ? "iphone" : "cloud")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if correction.status == "running" { ProgressView().controlSize(.small) }
                Text(correction.statusTitle).font(.caption)
                    .foregroundStyle(correction.hasResult ? Color.green : Color.secondary)
            }
            Text("\(correction.model) · \(BenchFormat.seconds(correction.elapsedMS))")
                .font(.caption2).foregroundStyle(.secondary)
            if correction.hasResult, let text = correction.text { ExpandableTranscript(text: text) }
            if correction.status == "running" {
                Text("已处理 \(correction.blocks.count) 个片段").font(.caption).foregroundStyle(.secondary)
            }
            if let error = correction.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if showDetails {
                ForEach(correction.blocks.filter { $0.original != $0.proposed || !$0.note.isEmpty }) { block in
                    DisclosureGroup("片段 \(block.id + 1) 的纠错建议") {
                        Text("原文：\(block.original)").font(.caption)
                        if let proposed = block.proposed {
                            diff(original: block.original, revised: proposed).font(.caption).textSelection(.enabled)
                            Text(block.applied == proposed ? "已应用" : "保留原文").font(.caption2)
                        }
                        Text(block.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("correction.result.\(provider.rawValue)")
    }

    private func diff(original: String, revised: String) -> Text {
        TextDiff.edits(from: original, to: revised).reduce(Text("建议：")) { text, edit in
            switch edit.kind {
            case .unchanged: return text + Text(edit.text)
            case .removed: return text + Text(edit.text).foregroundColor(.red).strikethrough()
            case .added: return text + Text(edit.text).foregroundColor(.green).bold()
            }
        }
    }
}
