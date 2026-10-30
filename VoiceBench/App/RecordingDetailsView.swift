import SwiftUI
import VoiceBenchCore

struct RecordingDetailsView: View {
    @ObservedObject var model: BenchViewModel
    let recordingID: UUID
    private var recording: Recording? { model.recordings.first { $0.id == recordingID } }

    var body: some View {
        Form {
            if let recording {
                if model.busy { Section { WorkStatusView(model: model) } }
                Section("录音") {
                    LabeledContent("时长", value: BenchFormat.clock(recording.duration))
                    LabeledContent("音频", value: "\(Int(recording.sampleRate)) Hz · \(recording.channels) 声道")
                    LabeledContent("创建时间") { Text(recording.createdAt, style: .date) }
                    DisclosureGroup("源文件 SHA-256") { Text(recording.sha256).font(.caption).textSelection(.enabled) }
                    Button("导出全部结果（JSON / Markdown）", systemImage: "square.and.arrow.up") {
                        model.export(recordingID: recordingID)
                    }.disabled(!model.idle)
                }
                Section("评测") {
                    Text("人工参考稿").font(.subheadline)
                    TextEditor(text: Binding(get: { self.recording?.reference ?? "" }, set: {
                        model.setReference($0, recordingID: recordingID)
                    }))
                    .frame(minHeight: 100).disabled(!model.idle).accessibilityLabel("人工参考稿")
                    Text("参考稿仅用于 CER 评测，不传给纠错模型。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("计算 / 更新 CER") { model.evaluate(recordingID: recordingID) }.disabled(!model.idle)
                }
                Section("纠错背景") {
                    TextEditor(text: Binding(get: { self.recording?.context ?? "" }, set: {
                        model.setContext(String($0.prefix(1000)), recordingID: recordingID)
                    }))
                    .frame(minHeight: 80).disabled(!model.idle).accessibilityLabel("纠错背景与词条")
                    Text("可填已确认的人名、地名或背景，最多 1000 字。原始识别文字始终保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("全部运行记录") {
                    if recording.runs.isEmpty { Text("尚无识别结果").foregroundStyle(.secondary) }
                    ForEach(recording.runs.reversed()) { run in
                        DisclosureGroup {
                            RunTranscriptView(run: run)
                            Text("初始化 \(BenchFormat.seconds(run.preparationMS)) · 处理 \(BenchFormat.seconds(run.transcriptionMS))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let rtf = run.rtf(duration: recording.duration) {
                                Text(String(format: "RTF %.3f", rtf)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let evaluation = model.evaluations[run.id] {
                                Text("原文 CER \(BenchFormat.percent(evaluation.rawCER?.rate)) · Apple 纠错 \(BenchFormat.percent(evaluation.correctedCER?.rate)) · DeepSeek 纠错 \(BenchFormat.percent(evaluation.deepSeekCER?.rate))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if run.status == .completed {
                                if run.hasCorrectionAttempts {
                                    Menu("纠错操作") {
                                        Button("重新运行 Apple + DeepSeek 纠错", systemImage: "arrow.clockwise") {
                                            model.correct(runID: run.id, recordingID: recordingID)
                                        }
                                    }
                                    .disabled(!model.idle || run.rawText.isEmpty)
                                } else {
                                    Button("运行 Apple + DeepSeek 纠错") { model.correct(runID: run.id, recordingID: recordingID) }
                                        .buttonStyle(.borderless).disabled(!model.idle || run.rawText.isEmpty)
                                }
                            }
                            if run.hasCorrectionAttempts { CorrectionResultsView(run: run, showDetails: true) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.engine.title)
                                Text(run.startedAt, format: .dateTime.month().day().hour().minute().second())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    DisclosureGroup("调试运行") {
                        Button("仅 SenseVoice") { model.run([.senseVoice], recordingID: recordingID) }
                            .disabled(!model.idle || model.modelReceipt == nil)
                        Button("仅 Apple") { model.run([.apple], recordingID: recordingID) }
                            .disabled(!model.idle || !model.appleReady)
                        Button("仅 \(EngineID.qwen.title)") { model.run([.qwen], recordingID: recordingID) }
                            .disabled(!model.idle || model.qwenModelReceipt == nil)
                    }
                }
            } else { Text("该录音已删除。").foregroundStyle(.secondary) }
        }
        .navigationTitle(recording?.name ?? "录音详情").navigationBarTitleDisplayMode(.inline)
        .onAppear { model.selectedID = recordingID }
    }
}
