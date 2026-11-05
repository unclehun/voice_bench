import VoiceBenchCore

struct EngineOutput: Sendable {
    var preparationMS: Double
    var transcriptionMS: Double
    var segments: [Segment]
    var configuration: [String: String]
    var text: String { segments.map(\.text).joined(separator: "\n") }
}
