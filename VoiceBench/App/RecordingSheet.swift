import SwiftUI
import UniformTypeIdentifiers

struct RecordingSheet: View {
    @ObservedObject var model: BenchViewModel
    @State private var audioPicker = false

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text("新录音").font(.headline)
                Spacer()
                Button("关闭") { model.showRecorder = false }
                    .disabled(model.isRecording || model.busy)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(BenchFormat.clock(model.recordingStartedAt.map { context.date.timeIntervalSince($0) } ?? model.recordedSeconds))
                    .font(.system(size: 42, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("录音时长")
            }
            // There is only one control in the hierarchy: record OR stop.
            if model.isRecording {
                Button { model.stopRecording() } label: {
                    RoundedRectangle(cornerRadius: 7).fill(.green).frame(width: 32, height: 32)
                        .frame(width: 76, height: 76)
                        .overlay(Circle().stroke(Color.green.opacity(0.3), lineWidth: 2))
                }
                .accessibilityLabel("停止并保存录音").accessibilityIdentifier("recorder.stop")
            } else {
                Button { model.startRecording() } label: {
                    Circle().fill(.red).frame(width: 56, height: 56)
                        .frame(width: 76, height: 76)
                        .overlay(Circle().stroke(Color.red.opacity(0.3), lineWidth: 2))
                }
                .disabled(model.busy)
                .accessibilityLabel("开始录音").accessibilityIdentifier("recorder.start")
            }
            if model.busy {
                HStack { ProgressView(); Text(model.message).font(.footnote) }
            } else {
                Text(model.isRecording ? "录音中，点击方块停止并保存" : "点击红色圆形开始录音")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("导入音频文件", systemImage: "folder") { audioPicker = true }
                .font(.footnote).disabled(model.isRecording || model.busy)
        }
        .padding(24)
        .presentationDetents([.height(360), .medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(model.isRecording || model.busy)
        .benchErrorAlert(model: model)
        .fileImporter(isPresented: $audioPicker, allowedContentTypes: [.wav, .mpeg4Audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importAudio(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
    }
}
