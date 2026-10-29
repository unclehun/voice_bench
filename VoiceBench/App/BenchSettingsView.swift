import SwiftUI
import UniformTypeIdentifiers
import VoiceBenchCore

struct BenchSettingsView: View {
    @ObservedObject var model: BenchViewModel
    @State private var sensePicker = false
    @State private var qwenPicker = false
    @State private var funASRPicker = false
    @State private var confirmClear = false
    @State private var deepSeekAPIKey = ""

    var body: some View {
        Form {
            if model.busy { Section { WorkStatusView(model: model) } }
            Section("模型选择和配置") {
                status("SenseVoiceSmall INT8", detail: model.modelDetail, ready: model.modelReceipt != nil)
                Button("从默认目录载入 SenseVoice") { model.importDefaultModels() }.disabled(!model.idle)
                Button("选择其他 SenseVoice 目录…", systemImage: "folder") { sensePicker = true }.disabled(!model.idle)
                Text("文件 → 在我的 iPhone → 语音对比 → SenseVoiceSmall_INT8")
                    .font(.caption).foregroundStyle(.secondary)
                Text("SenseVoice 自动检测录音语言，无需手动选择。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple Speech") {
                Picker("默认识别语言", selection: Binding(get: { model.appleLocaleIdentifier }, set: model.setAppleLocaleIdentifier)) {
                    ForEach(model.appleLocaleOptions, id: \.self) { identifier in
                        Text("\(AppleSpeechSettings.displayName(identifier)) · \(identifier)").tag(identifier)
                    }
                }
                .disabled(!model.idle).accessibilityIdentifier("settings.apple.locale")
                status("Apple Speech", detail: model.speech.detail, ready: model.speech.installed)
                if model.speech.available {
                    Button("准备默认语言的苹果资源（需要联网）") { model.prepareApple() }.disabled(!model.idle)
                }
                Text("默认中文（中国大陆）。Apple 直接识别整段录音，不做前置语言检测或语言分段；切换语言后会检查对应资源。语言选择保存在 App 数据目录，重启和覆盖更新后继续使用。")
                    .font(.caption).foregroundStyle(.secondary)
                status("本地文字纠错", detail: model.correctionUnavailable ?? "系统文字模型可用", ready: model.correctionUnavailable == nil)
            }
            Section {
                status("Qwen3-ASR 0.6B INT8", detail: model.qwenModelDetail, ready: model.qwenModelReceipt != nil)
                Button("从默认目录载入 Qwen3-ASR") { model.importQwenModels() }.disabled(!model.idle)
                Button("选择其他 Qwen3-ASR 目录…", systemImage: "folder") { qwenPicker = true }.disabled(!model.idle)
                Text("文件 → 在我的 iPhone → 语音对比 → Qwen3ASR_0_6B_INT8。请复制完整目录并保留 tokenizer 子目录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("约 1 GB；自动进行本地多语识别。配置完成后主界面识别会增加第三套引擎。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                status("Fun-ASR-MLT-Nano INT8", detail: model.funASRModelDetail, ready: model.funASRModelReceipt != nil)
                Button("从默认目录载入 Fun-ASR-MLT-Nano") { model.importFunASRModels() }.disabled(!model.idle)
                Button("选择其他 Fun-ASR-MLT-Nano 目录…", systemImage: "folder") { funASRPicker = true }.disabled(!model.idle)
                Text("文件 → 在我的 iPhone → 语音对比 → FunASR_MLT_Nano_INT8。请复制完整目录并保留 tokenizer 子目录。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("约 1 GB；自动进行本地多语识别。配置完成后主界面识别会增加 Fun-ASR 引擎。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("DeepSeek 公网纠错") {
                status(DeepSeekTextCorrector.modelDisplayName, detail: model.deepSeekKeyStatus, ready: model.deepSeekKeyConfigured)
                SecureField(model.deepSeekKeyConfigured ? "输入新的 API Key 以替换" : "DeepSeek API Key", text: $deepSeekAPIKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!model.idle).accessibilityIdentifier("settings.deepseek.api-key")
                Button(model.deepSeekKeyConfigured ? "更新 API Key" : "保存 API Key") {
                    if model.saveDeepSeekAPIKey(deepSeekAPIKey) { deepSeekAPIKey = "" }
                }
                .disabled(!model.idle || deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.deepseek.save")
                if model.deepSeekKeyConfigured {
                    Button("删除 API Key", role: .destructive) { model.removeDeepSeekAPIKey(); deepSeekAPIKey = "" }
                        .disabled(!model.idle)
                }
                Link("获取 DeepSeek API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                Text("保存后，点击纠错会同时运行 Apple 本地模型与 DeepSeek Flash（\(DeepSeekTextCorrector.model)，非思考模式）。仅识别文字和纠错背景通过 HTTPS 发送到 DeepSeek，不发送音频或人工参考稿；API 按用量计费。Key 保存在 App 私有数据目录，重启或覆盖更新后自动读取，不写入报告。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据管理") {
                Button("清除全部本机数据与模型", role: .destructive) { confirmClear = true }.disabled(!model.idle)
                Text("删除全部录音、识别、纠错、评测、模型、临时报告和 DeepSeek API Key，默认识别语言恢复中文。删除 App 时，配置随 App 数据一起删除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .onDisappear { deepSeekAPIKey = "" }
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
        .fileImporter(isPresented: $qwenPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importQwenModels(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $funASRPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.importFunASRModels(url) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .confirmationDialog("清除全部录音、结果、模型和 API Key？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除全部本机数据", role: .destructive) { model.clearAllData() }
        } message: {
            Text("此操作不可撤销，同时删除本机 DeepSeek API Key。也会释放本 App 的苹果语音资源预留；已导出副本、外部原件和苹果共享系统模型不在删除范围内。")
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
