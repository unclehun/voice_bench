import XCTest

final class DeepSeekCorrectionTests: XCTestCase {
    func testCorrectionProtocolAndPersistence() async throws {
        _ = try await DeepSeekChecks.run()
    }
}
