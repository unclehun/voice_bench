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
        latestComparisonRuns.contains { $0.deepSeekResult.hasResult }
    }

    var hasCorrectionAttempts: Bool {
        latestComparisonRuns.contains(where: { $0.hasCorrectionAttempts })
    }
}

public extension Run {
    var deepSeekResult: Correction { deepSeekCorrection ?? DeepSeekTextCorrector.initialCorrection() }
    var hasCorrectionAttempts: Bool { deepSeekResult.status != "not_requested" }
}

public extension Correction {
    var statusTitle: String {
        switch status {
        case "not_requested": return "尚未纠错"
        case "running": return "纠错中"
        case "completed": return "处理完成"
        case "partial": return "部分完成"
        case "failed": return "失败"
        case "cancelled": return "已停止"
        case "interrupted": return "已中断"
        case "skipped_empty": return "无识别文字"
        case "skipped_unconfigured": return "未配置 API Key"
        default: return status
        }
    }

    var hasResult: Bool {
        guard text != nil else { return false }
        if let document {
            return ["completed", "partial"].contains(status) ||
                (["cancelled", "interrupted"].contains(status) && !document.changes.isEmpty)
        }
        return ["completed", "partial", "cancelled", "interrupted"].contains(status)
    }
}
