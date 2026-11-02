import SwiftUI
import VoiceBenchCore

struct RecordingCard: View {
    @ObservedObject var model: BenchViewModel
    let recording: Recording
    let delete: () -> Void

    private var runs: [Run] { recording.latestComparisonRuns }
    private var recognizing: Bool { model.activeRecordingID == recording.id && model.activity == .recognition }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 14) {
                ForEach(EngineID.allCases) { engine in
                    if let run = runs.first(where: { $0.engine == engine }) {
                        RunResultCard(model: model, recordingID: recording.id, run: run)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(engine.title).font(.subheadline.weight(.semibold))
                            Text((engine == .qwen && model.qwenModelReceipt == nil)
                                 ? "尚未配置模型，可在设置中载入" : (runs.isEmpty ? "尚未识别" : "本轮未运行"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.secondary.opacity(0.16)))
                    }
                }
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
            Button { model.runComparison(recordingID: recording.id) } label: {
                Text(recognizing ? "识别中…" : "识别").font(.subheadline.weight(.medium)).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).disabled(!model.idle)
            .accessibilityLabel("依次识别 \(recording.name) 的 \(model.comparisonEngines.count) 套引擎结果")
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
            if let identifier = run.configuration["apple_locale"] {
                Text("识别语言：\(AppleSpeechSettings.displayName(identifier)) · 整段直接识别")
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
