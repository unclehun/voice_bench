import Foundation

public enum CorrectionProvider: String, CaseIterable, Identifiable, Sendable {
    case apple, deepSeek
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .apple: return "Apple 本地纠错"
        case .deepSeek: return "DeepSeek Flash 公网纠错"
        }
    }
}

public extension Run {
    func correction(for provider: CorrectionProvider) -> Correction {
        switch provider {
        case .apple: return correction
        case .deepSeek: return deepSeekCorrection ?? DeepSeekTextCorrector.initialCorrection()
        }
    }

    mutating func setCorrection(_ value: Correction, for provider: CorrectionProvider) {
        switch provider {
        case .apple: correction = value
        case .deepSeek: deepSeekCorrection = value
        }
    }

    var hasCorrectionAttempts: Bool {
        CorrectionProvider.allCases.contains { correction(for: $0).status != "not_requested" }
    }
}

public extension Correction {
    var statusTitle: String {
        switch status {
        case "not_requested": return "尚未纠错"
        case "running": return "纠错中"
        case "completed": return "完成"
        case "partial": return "部分完成"
        case "failed": return "失败"
        case "cancelled": return "已停止"
        case "interrupted": return "已中断"
        case "skipped_empty": return "无识别文字"
        case "skipped_unconfigured": return "未配置 API Key"
        case "skipped_unavailable": return "模型不可用"
        default: return status
        }
    }
}
