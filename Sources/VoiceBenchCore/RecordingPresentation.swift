import Foundation

public extension Recording {
    /// A newly queued comparison must not show the previous comparison's other engine result.
    /// Records created before batch IDs existed retain the latest result for each engine.
    var latestComparisonRuns: [Run] {
        guard let latest = runs.last else { return [] }
        return EngineID.allCases.compactMap { engine in
            runs.last { run in
                run.engine == engine && (latest.batchID == nil || run.batchID == latest.batchID)
            }
        }
    }

    var correctionCandidates: [Run] {
        latestComparisonRuns.filter { $0.status == .completed && !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var hasCorrectionResults: Bool {
        latestComparisonRuns.contains { $0.correction.hasResult }
    }
}

public extension Correction {
    var hasResult: Bool { (status == "completed" || status == "partial") && text != nil }
}
