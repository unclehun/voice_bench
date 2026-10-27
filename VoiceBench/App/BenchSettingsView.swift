import SwiftUI
import UniformTypeIdentifiers

struct BenchSettingsView: View {
    @ObservedObject var model: BenchViewModel
    @State private var sensePicker = false
    @State private var whisperPicker = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            if model.busy { Section { WorkStatusView(model: model) } }
            Section("模型选择和配置") {
                status("SenseVoiceSmall INT8", detail: model.modelDetail, ready: model.modelReceipt != nil)
                Button("从默认目录载入 SenseVoice") { model.importDefaultModels() }.disabled(!model.idle)
                Button("选择其他 SenseVoice 目录…", systemImage: "folder") { sensePicker = true }.disabled(!model.idle)
                Text("文件 → 在我的 iPhone → 语音对比 → SenseVoiceSmall_INT8")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                status("Whisper Tiny INT8 · 自动语言检测", detail: model.languageModelDetail, ready: model.languageModelReceipt != nil)
                Button("从默认目录载入 Whisper") { model.importLanguageModels() }.disabled(!model.idle)
                Button("选择其他 Whisper 目录…", systemImage: "folder") { whisperPicker = true }.disabled(!model.idle)
                Text("文件 → 在我的 iPhone → 语音对比 → WhisperTiny_INT8。需要 encoder、decoder 和 silero_vad 三个 ONNX 文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                status("Apple Speech", detail: model.speech.detail, ready: model.speech.installed)
                if model.speech.available {
                    Button("准备苹果语言资源（需要联网）") { model.prepareApple() }.disabled(!model.idle)
                }
                Text("默认准备中文、英文；检测到其他语言后可再次准备。识别时自动检测语言，句内混说按片段主要语言处理。")
                    .font(.caption).foregroundStyle(.secondary)
                status("本地文字纠错", detail: model.correctionUnavailable ?? "系统文字模型可用", ready: model.correctionUnavailable == nil)
            }
            Section("系统配置") {
                Picker("SenseVoice 语言", selection: $model.language) {
                    Text("自动检测").tag("auto"); Text("中文").tag("zh"); Text("英文").tag("en")
                }
                Toggle("低内存模式", isOn: $model.lowMemory)
                Toggle("下一轮 Apple 先运行", isOn: $model.appleFirst)
                Text("两套引擎依次运行，每轮自动交换顺序。默认 2 线程、25 秒分段；低内存模式使用 1 线程、12 秒分段。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.idle)
            Section("数据管理") {
                Button("清除全部本机数据与模型", role: .destructive) { confirmClear = true }.disabled(!model.idle)
                Text("删除全部录音、识别、纠错、评测、模型和临时报告。移除 App 时选择“删除 App”才能一并删除数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("检查状态", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .labelStyle(.iconOnly).disabled(!model.idle)
            }
        }
        .fileImporter(isPresented: $sensePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importModels(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $whisperPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importLanguageModels(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .confirmationDialog("清除全部录音、结果和导入模型？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除全部本机数据", role: .destructive) { model.clearAllData() }
        } message: {
            Text("此操作不可撤销。也会释放本 App 的苹果语音资源预留；已导出副本、外部原件和苹果共享系统模型不在删除范围内。")
        }
    }

    private func status(_ title: String, detail: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
