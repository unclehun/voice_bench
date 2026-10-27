import SwiftUI
import AVFoundation
import VoiceBenchCore

struct BenchView: View {
    @ObservedObject var model: BenchViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingDeletion: Recording?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 18) {
                    if model.busy { WorkStatusView(model: model) }
                    if model.recordings.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.recordings) { recording in
                            RecordingCard(model: model, recording: recording) { pendingDeletion = recording }
                        }
                    }
                    if !model.bothReady {
                        NavigationLink {
                            BenchSettingsView(model: model)
                        } label: {
                            Label("请在设置中完成模型配置", systemImage: "slider.horizontal.3")
                                .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("语音对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.openRecorder() } label: { Image(systemName: "plus").font(.title3) }
                        .accessibilityLabel("添加录音").accessibilityIdentifier("recording.add")
                        .disabled(!model.idle)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { BenchSettingsView(model: model) } label: { Text("设置") }
                        .accessibilityIdentifier("settings.open")
                }
            }
            .confirmationDialog("删除录音及其全部数据？", isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible) {
                if let target = pendingDeletion {
                    Button("删除", role: .destructive) {
                        model.delete(recordingID: target.id)
                        pendingDeletion = nil
                    }
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("将删除“\(pendingDeletion?.name ?? "")”的音频、全部识别与纠错结果、评测和临时文件。")
            }
        }
        .benchErrorAlert(model: model, enabled: !model.showRecorder)
        .sheet(isPresented: $model.showRecorder) { RecordingSheet(model: model) }
        .sheet(isPresented: $model.showShare, onDismiss: model.finishSharing) { ShareSheet(items: model.shareFiles) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.backgrounded() } }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue { model.backgrounded() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text("还没有录音").font(.title3.weight(.semibold))
            Text("点击左上角 +，录下第一段语音")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("开始录音") { model.openRecorder() }
                .buttonStyle(.borderedProminent).disabled(!model.idle)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 70)
    }
}

struct WorkStatusView: View {
    @ObservedObject var model: BenchViewModel
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(model.message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if model.activity != nil && !model.isClearingData {
                Button("停止") { model.cancel() }.font(.footnote)
            }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}
