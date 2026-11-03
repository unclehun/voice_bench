import SwiftUI
import UIKit
import VoiceBenchCore

struct DeepSeekRequestLogsView: View {
    let logs: [DeepSeekRequestLog]
    @State private var selected: DeepSeekRequestLog?

    var body: some View {
        DisclosureGroup("DeepSeek 请求日志（\(logs.count)）") {
            ForEach(logs.reversed()) { log in
                Button { selected = log } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(log.startedAt, format: .dateTime.month().day().hour().minute().second())
                            Text("第 \(log.attempt) 次 · \(log.stateTitle)")
                                .foregroundStyle(log.state == "failed" ? Color.red : Color.secondary)
                        }
                        .font(.caption)
                        Text("操作 \(log.operationID.uuidString.prefix(8))").font(.caption2).foregroundStyle(.secondary)
                        if let error = log.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("deepseek.log.\(log.id)")
            }
            Text("保留最近20次请求；自动重试、再次纠错及重启不会覆盖此前日志。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityIdentifier("deepseek.logs")
        .sheet(item: $selected) { log in
            NavigationStack {
                ScrollView {
                    Text(log.formatted)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("DeepSeek 请求日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭") { selected = nil } }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: log.formatted) { Label("分享日志", systemImage: "square.and.arrow.up") }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("复制完整日志", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.formatted }
                    }
                }
            }
        }
    }
}
