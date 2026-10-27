import SwiftUI
import UIKit

// Shared formatting and presentation keep the recording sheet and cards consistent.
enum BenchFormat {
    static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
    static func seconds(_ milliseconds: Double?) -> String {
        milliseconds.map { String(format: "%.2f s", $0 / 1000) } ?? "—"
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "—" }
}

extension View {
    @MainActor
    func benchErrorAlert(model: BenchViewModel, enabled: Bool = true) -> some View {
        alert("操作未完成", isPresented: Binding(
            get: { enabled && model.error != nil }, set: { if !$0 && enabled { model.error = nil } }
        )) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
