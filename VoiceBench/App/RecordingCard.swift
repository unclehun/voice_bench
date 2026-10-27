import SwiftUI
import VoiceBenchCore

struct RecordingCard: View {
    @ObservedObject var model: BenchViewModel
    let recording: Recording
    let delete: () -> Void
    @State private var correctionExpanded = false

    private var runs: [Run] { recording.latestComparisonRuns }
    private var recognizing: Bool { model.activeRecordingID == recording.id && model.activity == .recognition }
    private var correcting: Bool { model.activeRecordingID == recording.id && model.activity == .correction }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 14) {
                ForEach(EngineID.allCases) { engine in
                    if engine == .apple { Divider() }
                    if let run = runs.first(where: { $0.engine == engine }) {
                        RunTranscriptView(run: run)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(engine.title).font(.subheadline.weight(.semibold))
                            Text(runs.isEmpty ? "尚未识别" : "本轮未运行")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 0) {
                        Button {
                            correctionExpanded = false
                            model.correctLatest(recordingID: recording.id)
                        } label: {
                            HStack(spacing: 6) {
                                if correcting { ProgressView().controlSize(.small) }
                                Text(correcting ? "纠错中…" : "纠错")
                            }
                            .padding(.horizontal, 16).frame(minHeight: 44)
                        }
                        .disabled(!model.idle || recording.correctionCandidates.isEmpty)
                        .accessibilityIdentifier("correction.run.\(recording.id)")
                        if recording.hasCorrectionResults && !correcting {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { correctionExpanded.toggle() }
                            } label: {
                                Image(systemName: "triangle.fill")
                                    .rotationEffect(.degrees(correctionExpanded ? 180 : 0))
                                    .foregroundStyle(.green).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(correctionExpanded ? "收起纠错结果" : "展开纠错结果")
                            .accessibilityIdentifier("correction.toggle.\(recording.id)")
                            .accessibilityValue(correctionExpanded ? "已展开" : "已收起")
                        }
                    }
                    .buttonStyle(.plain)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3)).allowsHitTesting(false))
                }
                if !correcting, let failed = runs.first(where: {
                    ["failed", "skipped_unavailable", "cancelled", "interrupted"].contains($0.correction.status)
                }), let error = failed.correction.error {
                    Text("\(failed.engine.title) 纠错：\(error)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.16)))

            if correctionExpanded && recording.hasCorrectionResults && !correcting {
                VStack(alignment: .leading, spacing: 14) {
                    Text("纠错结果").font(.subheadline.weight(.semibold))
                    ForEach(runs.filter { $0.correction.hasResult }) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(run.engine.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ExpandableTranscript(text: run.correction.text ?? "")
                            if let error = run.correction.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.green.opacity(0.25)))
            }
            HStack {
                NavigationLink { RecordingDetailsView(model: model, recordingID: recording.id) } label: {
                    Text("详情").font(.footnote).frame(minHeight: 44)
                }
                Spacer()
                Button(role: .destructive, action: delete) { Text("删除").font(.footnote).frame(minHeight: 44) }
                    .disabled(!model.idle)
                    .accessibilityLabel("删除录音 \(recording.name) 及全部结果")
            }
            .buttonStyle(.borderless).frame(minHeight: 30)
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.secondary.opacity(0.18)))
        .onChange(of: runs.map(\.id)) { _, _ in correctionExpanded = false }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { model.play(recordingID: recording.id) } label: {
                HStack(spacing: 12) {
                    Image(systemName: model.playingID == recording.id ? "stop.fill" : "play.fill")
                        .font(.title3).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(recording.name).font(.headline).lineLimit(1)
                        Text(BenchFormat.clock(recording.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary).frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!model.idle)
            .accessibilityLabel("\(model.playingID == recording.id ? "停止播放" : "播放") \(recording.name)")
            Button { model.runBoth(recordingID: recording.id) } label: {
                Text(recognizing ? "识别中…" : "识别").font(.subheadline.weight(.medium)).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(!model.idle)
            .accessibilityLabel("依次识别 \(recording.name) 的两套引擎结果")
            .accessibilityIdentifier("recognition.run.\(recording.id)")
        }
    }
}

struct RunTranscriptView: View {
    let run: Run
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(run.engine.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(status).font(.caption).foregroundStyle(run.status == .completed ? Color.green : Color.secondary)
            }
            if !run.rawText.isEmpty { ExpandableTranscript(text: run.rawText) }
            else { Text(run.status == .completed ? "未检测到语音" : "暂无文字").font(.subheadline).foregroundStyle(.secondary) }
            if let error = run.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let detection = run.languageDetection, !detection.languages.isEmpty {
                Text("自动语言：\(detection.languages.map(LanguageRouting.name).joined(separator: "、"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var status: String {
        switch run.status {
        case .running: return run.configuration["execution_state"] == "queued" ? "等待运行" : "识别中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已停止"
        case .interrupted: return "已中断"
        }
    }
}

struct ExpandableTranscript: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.subheadline).lineLimit(expanded || text.count <= 160 ? nil : 6)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if text.count > 160 {
                Button(expanded ? "收起文字" : "展开全文") { expanded.toggle() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.tint)
            }
        }
    }
}
