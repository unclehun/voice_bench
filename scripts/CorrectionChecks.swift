import Foundation

@main
struct CorrectionChecks {
    static func main() async throws {
        let count = try await DeepSeekChecks.run()
        print("PASS: \(count) correction checks (mock HTTP, no API key or live service used).")
    }
}
