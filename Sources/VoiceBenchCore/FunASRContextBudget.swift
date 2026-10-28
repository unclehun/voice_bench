import Foundation

/// Contract for the pinned 932d7db MLT graphs and sherpa-onnx 1.13.8.
/// Budgets are conservative upper bounds, not language-ID confidence or exact encoder counts.
public struct FunASRContextBudget: Sendable {
    public static let capacity = 512
    public static let safetyTokens = 16
    public static let minimumOutputTokens = 64
    public static let systemPrompt = "You are a helpful assistant."
    public static let userPrompt = "语音转写："
    // Verified with the pinned native tokenizer: 18 tokens before audio + 5 after.
    public static let promptTokens = 23
    public let sampleCount: Int
    public let audioTokensUpperBound: Int
    public var prefillUpperBound: Int { Self.promptTokens + audioTokensUpperBound }
    public var availableOutputTokens: Int { max(0, Self.capacity - Self.safetyTokens - prefillUpperBound) }
    public var canDecode: Bool { sampleCount > 0 && sampleCount <= 32 * 16000 && availableOutputTokens >= Self.minimumOutputTokens }

    public init(sampleCount: Int) {
        self.sampleCount = sampleCount
        // 16 kHz / 10 ms mel frames; account for endpoint rounding, then LFR 7:6.
        // The pinned encoder/adaptor does not expand this sequence. Round up with slack.
        let melFrames = max(0, sampleCount) / 160 + (sampleCount % 160 == 0 ? 0 : 1) + 2
        audioTokensUpperBound = (melFrames + 5) / 6 + 2
    }

    /// If KV exhaustion stopped decoding, the native count cannot pass this check.
    /// Near-limit EOS may be retried too; never accept an ambiguous truncated result.
    public func accepts(generatedTokens: Int) -> Bool {
        canDecode && generatedTokens >= 0 && generatedTokens < Int(FunASRModel.maximumNewTokens)
            && generatedTokens <= availableOutputTokens
    }
}

public enum FunASRChunkBoundary {
    public static let maximumRetryDepth = 4
    public static let minimumChildFrames = 2 * 16000

    /// A forced VAD limit can leave a few syllables at EOF. Keep one span pending
    /// so a neighbouring short tail is decoded with context, rather than on its own.
    public static func shouldMerge(previousStart: Int64, previousEnd: Int64, nextStart: Int64, nextEnd: Int64) -> Bool {
        let gap = max(0, nextStart - previousEnd)
        return previousEnd > previousStart && nextEnd > nextStart && nextStart >= previousStart
            && gap <= 3200 && max(previousEnd, nextEnd) - previousStart <= 32 * 16000
            && min(previousEnd - previousStart, nextEnd - nextStart) < Int64(minimumChildFrames)
    }

    /// Split at low energy near the middle. Child intervals meet at one exact sample:
    /// no audio is discarded, duplicated, or text-matched heuristically.
    public static func splitOffset(samples: [Float], depth: Int) -> Int? {
        guard depth < maximumRetryDepth, samples.count >= minimumChildFrames * 2,
              samples.allSatisfy({ $0.isFinite }) else { return nil }
        let middle = samples.count / 2
        let radius = min(2 * 16000, samples.count / 4)
        let lower = max(minimumChildFrames, middle - radius)
        let upper = min(samples.count - minimumChildFrames, middle + radius)
        guard lower <= upper else { return nil }
        let halfWindow = 640 // 80 ms total, scored every 10 ms.
        var sums = Array(repeating: 0.0, count: samples.count + 1)
        for i in samples.indices { sums[i + 1] = sums[i] + Double(samples[i]) * Double(samples[i]) }
        var best = middle
        var bestScore = Double.infinity
        for center in stride(from: lower, through: upper, by: 160) {
            let lo = max(0, center - halfWindow), hi = min(samples.count, center + halfWindow)
            let power = (sums[hi] - sums[lo]) / Double(hi - lo)
            let distance = Double(abs(center - middle)) / Double(max(1, radius))
            let score = power * (1 + 0.05 * distance) + 1e-12 * distance
            if score < bestScore { best = center; bestScore = score }
        }
        return best
    }
}
