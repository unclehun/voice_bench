import SwiftUI

@main
struct VoiceBenchApp: App {
    @StateObject private var model = BenchViewModel()
    var body: some Scene {
        WindowGroup { BenchView(model: model) }
    }
}
