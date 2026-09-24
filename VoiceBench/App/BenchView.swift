import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import VoiceBenchCore

struct BenchView: View {
    @ObservedObject var model: BenchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var audioPicker = false
    @State private var modelPicker = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Image(systemName: model.busy ? "waveform" : "waveform.circle")
                            .foregroundStyle(.tint)
                        Text(model.message).font(.subheadline)
                        if model.busy { Spacer(); ProgressView() }
                    }
                    if model.busy { Button("取消当前任务", role: .cancel) { model.cancel() } }
                }

                Section("1 · 音频") {
                    HStack {
                        if model.isRecording {
                            Button(role: .destructive) { model.stopRecording() } label: { Label("停止录音", systemImage: "stop.fill") }
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(clock(context.date.timeIntervalSince(model.recordingStartedAt ?? context.date)))
                                    .monospacedDigit().foregroundStyle(.red)
                            }
                        } else {
                            Button { model.startRecording() } label: { Label("录音", systemImage: "mic") }
                                .disabled(model.busy)
                            Spacer()
                            Button { audioPicker = true } label: { Label("导入音频", systemImage: "folder") }
                                .disabled(model.busy)
                        }
                    }.buttonStyle(.borderless)
                    if !model.recordings.isEmpty {
                        Picker("已保存录音", selection: $model.selectedID) {
                            ForEach(model.recordings) { item in
                                Text("\(item.name) · \(clock(item.duration))").tag(Optional(item.id))
                            }
                        }.disabled(model.busy || model.isRecording)
                    }
                    if let item = model.current {
                        Text("\(clock(item.duration)) · \(Int(item.sampleRate)) Hz · \(item.channels) 声道")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("播放", systemImage: "play") { model.play() }
                            Button("停止", systemImage: "stop") { model.stopPlayback() }
                            Spacer()
                            Button("删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        }.buttonStyle(.borderless).disabled(!model.canRun)
                    }
                }

                Section {
                    statusRow("SenseVoiceSmall INT8", detail: model.modelReceipt == nil ? "需要导入模型目录" : "模型文件就绪", ready: model.modelReceipt != nil)
                    Button("导入模型目录") { modelPicker = true }.disabled(model.busy || model.isRecording)
                    statusRow("Apple SpeechTranscriber", detail: model.speech.detail, ready: model.speech.installed)
                    if model.speech.available && !model.speech.installed {
                        Button("准备苹果中文资源（需要联网）") { model.prepareApple() }.disabled(model.busy || model.isRecording)
                    }
                    DisclosureGroup("识别设置") {
                        Picker("SenseVoice 语言", selection: $model.language) {
                            Text("自动检测").tag("auto"); Text("中文").tag("zh")
                        }
                        Toggle("低内存模式", isOn: $model.lowMemory)
                        Text("默认 2 线程、25 秒分段；低内存模式使用 1 线程、12 秒分段。苹果识别始终使用系统中文资源。")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("下一轮苹果先运行", isOn: $model.appleFirst)
                    }.disabled(model.busy || model.isRecording)
                    Button {
                        model.runBoth()
                    } label: {
                        Label("依次运行两套引擎", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }.buttonStyle(.borderedProminent).disabled(!model.canRun || !model.bothReady)
                    HStack {
                        Button("仅 SenseVoice") { model.run([.senseVoice]) }.disabled(!model.canRun || model.modelReceipt == nil)
                        Spacer()
                        Button("仅 Apple") { model.run([.apple]) }.disabled(!model.canRun || !model.speech.installed)
                    }.buttonStyle(.borderless)
                } header: {
                    Text("2 · 引擎")
                } footer: {
                    Text("准备资源后可断网识别。两套引擎读取同一份音频；不会使用云端识别或替代引擎。")
                }

                if let item = model.current {
                    Section("3 · 结果") {
                        if item.runs.isEmpty {
                            Text("尚未转写").foregroundStyle(.secondary)
                        }
                        ForEach(item.runs.reversed()) { run in
                            ResultView(run: run, duration: item.duration, evaluation: model.evaluations[run.id],
                                       canCorrect: model.canRun && run.status == .completed) {
                                model.correct(runID: run.id)
                            }
                        }
                    }
                    Section("4 · 评测与导出") {
                        Text("人工参考稿").font(.subheadline)
                        TextEditor(text: Binding(get: { model.current?.reference ?? "" }, set: model.setReference))
                            .frame(minHeight: 100).disabled(model.busy)
                            .accessibilityLabel("人工参考稿，仅用于计算 CER")
                        Text("参考稿仅用于计算 CER，不会传给纠错模型。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("计算 / 更新 CER") { model.evaluate() }.disabled(!model.canRun)
                        DisclosureGroup("可选：本地文字纠错") {
                            if let reason = model.correctionUnavailable {
                                Text("当前不可用：\(reason)").font(.caption).foregroundStyle(.secondary)
                            } else { Text("本地文字模型可用").font(.caption).foregroundStyle(.green) }
                            Text("背景或已确认的人名、地名（最多 1000 字）").font(.caption)
                            TextEditor(text: Binding(get: { model.current?.context ?? "" }, set: model.setContext))
                                .frame(minHeight: 80).disabled(model.busy)
                            Text("转写完成后，在对应结果中单独执行。数字、否定等敏感修改保留为建议；原始文字始终保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("导出 JSON 和 Markdown", systemImage: "square.and.arrow.up") { model.export() }.disabled(!model.canRun)
                    }
                }
            }
            .navigationTitle("语音对比")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("检查状态", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.busy || model.isRecording)
                }
            }
            .fileImporter(isPresented: $audioPicker, allowedContentTypes: [.wav, .mpeg4Audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.importAudio(url) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $modelPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): if let url = urls.first { model.importModels(url) }
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .confirmationDialog("删除这条录音及其全部结果？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { model.deleteCurrent() }
            }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .sheet(isPresented: $model.showShare) { ShareSheet(items: model.shareFiles) }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() } }
            .onChange(of: model.selectedID) { _, _ in model.stopPlayback() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   type == AVAudioSession.InterruptionType.began.rawValue { model.backgrounded() }
            }
        }
    }

    private func statusRow(_ title: String, detail: String, ready: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct ResultView: View {
    let run: Run
    let duration: Double
    let evaluation: RunEvaluation?
    let canCorrect: Bool
    let correct: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(run.engine.title).font(.headline)
                Spacer()
                Text(status).font(.caption).foregroundStyle(run.status == .completed ? .green : .secondary)
            }
            Text(run.startedAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            if !run.rawText.isEmpty { Text(String(run.rawText.prefix(1200))).textSelection(.enabled) }
            else { Text(run.status == .completed ? "没有识别到语音" : "暂无文字").foregroundStyle(.secondary) }
            if run.rawText.count > 1200 {
                DisclosureGroup("查看完整文字") { Text(run.rawText).textSelection(.enabled) }
            }
            if let error = run.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("初始化 \(seconds(run.preparationMS)) · 转写 \(seconds(run.transcriptionMS)) · RTF \(number(run.rtf(duration: duration)))")
                .font(.caption).foregroundStyle(.secondary)
            if let evaluation {
                Text("CER \(percent(evaluation.rawCER?.rate)) · 纠错 CER \(percent(evaluation.correctedCER?.rate)) · Δ \(percent(evaluation.deltaCER))")
                    .font(.caption).monospacedDigit()
            }
            if !run.segments.isEmpty {
                DisclosureGroup("\(run.segments.count) 个片段") {
                    ForEach(run.segments) { segment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "%.1f–%.1f 秒", segment.startSeconds, segment.endSeconds)).font(.caption).foregroundStyle(.secondary)
                            Text(segment.text).font(.subheadline).textSelection(.enabled)
                        }
                    }
                }
            }
            DisclosureGroup("本地文字纠错") {
                Button(run.correction.status == "not_requested" ? "执行纠错" : "重新纠错", action: correct).disabled(!canCorrect)
                Text("状态：\(run.correction.status) · \(seconds(run.correction.elapsedMS))").font(.caption).foregroundStyle(.secondary)
                if let text = run.correction.text { Text(text).textSelection(.enabled) }
                if let error = run.correction.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                ForEach(run.correction.blocks.filter { $0.original != $0.proposed || !$0.note.isEmpty }) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("片段 \(block.id + 1)").font(.caption.weight(.semibold))
                        Text("原文：\(block.original)").font(.caption).foregroundStyle(.secondary)
                        if let proposed = block.proposed, proposed != block.original {
                            diff(original: block.original, revised: proposed).font(.caption).textSelection(.enabled)
                            Text(block.applied == proposed ? "已应用" : "未应用，保留原文").font(.caption2)
                        }
                        Text(block.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.padding(.vertical, 6)
    }
    private var status: String {
        switch run.status {
        case .running: return "转写中"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0 / 1000) } ?? "—" }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "—" }
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

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
