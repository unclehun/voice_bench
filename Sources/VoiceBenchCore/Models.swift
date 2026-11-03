import Foundation

public enum EngineID: String, Codable, CaseIterable, Identifiable, Sendable {
    case senseVoice = "sensevoice_small_int8"
    case apple = "apple_speechtranscriber"
    case qwen = "qwen3_asr_0_6b_weight_only4"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .senseVoice: return "SenseVoice"
        case .apple: return "Apple Speech"
        case .qwen: return "Qwen3-ASR 4 位"
        }
    }
}

public enum RunStatus: String, Codable, Sendable {
    case running, completed, failed, cancelled, interrupted
}

public struct Segment: Codable, Identifiable, Sendable {
    public var id: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var elapsedMS: Double?
    public var language: String?
    public init(id: Int, startSeconds: Double, endSeconds: Double, text: String, elapsedMS: Double? = nil, language: String? = nil) {
        self.id = id; self.startSeconds = startSeconds; self.endSeconds = endSeconds
        self.text = text; self.elapsedMS = elapsedMS; self.language = language
    }
}

public struct CorrectionBlock: Codable, Identifiable, Sendable {
    public var id: Int
    public var original: String
    public var proposed: String?
    public var applied: String
    public var note: String
    /// Nil for records produced by the original whole-block corrector.
    public var changes: [CorrectionChange]?
    public var state: String?
    public init(id: Int, original: String, proposed: String?, applied: String, note: String) {
        self.id = id; self.original = original; self.proposed = proposed; self.applied = applied; self.note = note
    }
}

/// One full-transcript result. Source offsets always refer to this immutable original.
public struct CorrectionDocument: Codable, Sendable {
    public var original: String
    public var changes: [CorrectionChange]
    public var isComplete: Bool
    public init(original: String, changes: [CorrectionChange] = [], isComplete: Bool = false) {
        self.original = original; self.changes = changes; self.isComplete = isComplete
    }
}

public struct Correction: Codable, Sendable {
    public var status: String = "not_requested"
    public var text: String?
    public var elapsedMS: Double?
    public var model = "deepseek-flash"
    public var promptVersion = SemanticCorrection.promptVersion
    public var promptHash: String?
    public var context: String = ""
    public var document: CorrectionDocument?
    public var attemptCount: Int?
    /// Read-only compatibility with older segmented results; new requests never populate blocks.
    public var blocks: [CorrectionBlock] = []
    public var error: String?
    public var policyVersion: String?
    public var semanticOverview: String?
    public var phase: String?
    public init() {}
}

public struct Run: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var batchID: UUID?
    public var engine: EngineID
    public var startedAt = Date()
    public var status: RunStatus = .running
    public var preparationMS: Double?
    public var transcriptionMS: Double?
    public var rawText = ""
    public var segments: [Segment] = []
    public var error: String?
    public var modelVersion: String
    public var configuration: [String: String] = [:]
    /// Optional because recordings may predate DeepSeek support or have no correction yet.
    public var deepSeekCorrection: Correction?
    public init(engine: EngineID) {
        self.engine = engine
        switch engine {
        case .apple: modelVersion = "system-managed/unknown"
        case .senseVoice: modelVersion = "sense-voice-int8-2024-07-17"
        case .qwen: modelVersion = QwenASRModel.version
        }
    }
    public func rtf(duration: Double) -> Double? {
        guard status == .completed, duration > 0, let ms = transcriptionMS else { return nil }
        return ms / 1000 / duration
    }
}

public struct Recording: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var revision: Int = 0
    public var createdAt = Date()
    public var name: String
    public var fileName: String
    public var sha256: String
    public var duration: Double
    public var sampleRate: Double
    public var channels: Int
    public var reference = ""
    public var context = ""
    public var runs: [Run] = []
    public init(name: String, fileName: String, sha256: String, duration: Double, sampleRate: Double, channels: Int) {
        self.name = name; self.fileName = fileName; self.sha256 = sha256
        self.duration = duration; self.sampleRate = sampleRate; self.channels = channels
    }
    public mutating func recoverInterruptedRuns() {
        for index in runs.indices {
            if runs[index].status == .running {
                runs[index].status = .interrupted
                runs[index].error = "上次运行未正常结束，请重新执行。"
            }
            runs[index].deepSeekCorrection?.recoverInterruption()
        }
    }
}

public struct BenchError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thread-safe cancellation for synchronous native inference. Cancellation is checked between segments.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    public func check() throws { if isCancelled { throw CancellationError() } }
}
