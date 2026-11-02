import SwiftUI
import VoiceBenchCore

/// One engine's result for one recording, including its own correction controls and results.
struct RunResultCard: View {
    @ObservedObject var model: BenchViewModel
    let recordingID: UUID
    let run: Run
    var showDetails = false
    @State private var correctionExpanded = true

    private var canCorrect: Bool {
        run.status == .completed && !run.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var correcting: Bool {
        model.activity == .correction && model.activeRecordingID == recordingID &&
        CorrectionProvider.allCases.contains { run.correction(for: $0).status == "running" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RunTranscriptView(run: run)

            if canCorrect || run.hasCorrectionAttempts {
                correctionControls
            }

            if run.hasCorrectionAttempts && correctionExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text("纠错结果").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    CorrectionResultsView(run: run, showDetails: showDetails, reviewEnabled: model.idle) { provider, changeID, accept in
                        model.reviewCorrection(changeID: changeID, accept: accept, provider: provider,
                                               runID: run.id, recordingID: recordingID)
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.vertical, 3)
                }
                .accessibilityIdentifier("correction.results.\(run.id)")
            }

            if showDetails {
                diagnostics
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.16)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recognition.result.\(run.id)")
        .onChange(of: run.id) { _, _ in correctionExpanded = true }
        .onChange(of: correcting) { _, value in if value { correctionExpanded = true } }
    }

    @ViewBuilder
    private var correctionControls: some View {
        if run.hasCorrectionAttempts {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { correctionExpanded.toggle() }
                } label: {
                    Label(correctionExpanded ? "收起纠错结果" : "查看纠错结果与状态",
                          systemImage: correctionExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("correction.toggle.\(run.id)")
                .accessibilityValue(correctionExpanded ? "已展开" : "已收起")

                Menu {
                    Button("重新纠错此结果（Apple + DeepSeek）", systemImage: "arrow.clockwise") {
                        startCorrection()
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .disabled(!model.idle || !canCorrect)
                .accessibilityLabel("\(run.engine.title) 此次识别的纠错操作")
                .accessibilityIdentifier("correction.rerun-menu.\(run.id)")
            }
            if correcting {
                Text("正在纠错此识别结果…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button {
                startCorrection()
            } label: {
                Label("纠错此结果", systemImage: "text.badge.checkmark")
                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered).disabled(!model.idle || !canCorrect)
            .accessibilityLabel("纠错 \(run.engine.title) 此次识别结果，运行 Apple 与 DeepSeek")
            .accessibilityIdentifier("correction.run.\(run.id)")
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("初始化 \(BenchFormat.seconds(run.preparationMS)) · 处理 \(BenchFormat.seconds(run.transcriptionMS))")
            if let recording = model.recordings.first(where: { $0.id == recordingID }), let rtf = run.rtf(duration: recording.duration) {
                Text(String(format: "RTF %.3f", rtf))
            }
            if let evaluation = model.evaluations[run.id] {
                Text("原文 CER \(BenchFormat.percent(evaluation.rawCER?.rate)) · Apple 纠错 \(BenchFormat.percent(evaluation.correctedCER?.rate)) · DeepSeek 纠错 \(BenchFormat.percent(evaluation.deepSeekCER?.rate))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func startCorrection() {
        correctionExpanded = true
        model.correct(runID: run.id, recordingID: recordingID)
    }
}
