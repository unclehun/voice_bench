import Foundation

public struct LanguageWindow: Codable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var language: String?
    public init(startSeconds: Double, endSeconds: Double, language: String?) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.language = language
    }
}

public struct DetectedSpeechSpan: Codable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var windows: [LanguageWindow]
    public init(startSeconds: Double, endSeconds: Double, windows: [LanguageWindow]) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.windows = windows
    }
}

public struct LanguageRegion: Codable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var language: String?
    /// detected / short_input / mixed_dominant / undetermined; not a calibrated probability.
    public var decision: String
    public var observedLanguages: [String]
    public init(startSeconds: Double, endSeconds: Double, language: String?, decision: String, observedLanguages: [String]) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.language = language
        self.decision = decision; self.observedLanguages = observedLanguages
    }
}

public struct LanguageDetection: Codable, Sendable {
    public static let modelVersion = "whisper-tiny-int8-65176e2"
    public var model = Self.modelVersion
    public var strategy = "vad-window-vote-v1"
    public var preparationMS: Double
    public var detectionMS: Double
    public var durationSeconds: Double
    public var spans: [DetectedSpeechSpan]
    public var regions: [LanguageRegion]
    public var languages: [String] { Array(Set(regions.compactMap(\.language))).sorted() }
    public init(preparationMS: Double, detectionMS: Double, durationSeconds: Double, spans: [DetectedSpeechSpan]) {
        self.preparationMS = preparationMS; self.detectionMS = detectionMS
        self.durationSeconds = durationSeconds; self.spans = spans
        regions = LanguageRouting.regions(spans: spans, duration: durationSeconds)
    }
}

public enum LanguageRouting {
    public static func name(_ code: String) -> String {
        ["zh": "中文", "en": "英语", "yue": "粤语", "ja": "日语", "ko": "韩语"][code]
            ?? Locale(identifier: "zh-CN").localizedString(forLanguageCode: code) ?? code
    }

    public static func normalized(_ code: String?) -> String? {
        guard let value = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (2...3).contains(value.count), value.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return value == "und" || value == "unk" ? nil : value
    }

    public static func regions(spans: [DetectedSpeechSpan], duration: Double) -> [LanguageRegion] {
        guard duration.isFinite, duration > 0 else { return [] }
        var result: [LanguageRegion] = []
        let ordered = spans.filter { $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.endSeconds > $0.startSeconds }
            .sorted(by: { $0.startSeconds < $1.startSeconds })
        for (index, span) in ordered.enumerated() {
            var votes: [String: Double] = [:]
            for window in span.windows {
                guard window.startSeconds.isFinite, window.endSeconds.isFinite,
                      let code = normalized(window.language) else { continue }
                let weight = max(0, min(window.endSeconds, span.endSeconds) - max(window.startSeconds, span.startSeconds))
                guard weight > 0 else { continue }
                votes[code, default: 0] += weight
            }
            let highest = votes.values.max() ?? 0
            let tied = Set(votes.filter { abs($0.value - highest) < 0.000001 }.map(\.key))
            let previous = result.last?.language
            let winner: String?
            if let previous, tied.contains(previous) { winner = previous }
            else { winner = span.windows.compactMap { normalized($0.language) }.first { tied.contains($0) } }
            let total = votes.values.reduce(0, +)
            let substantial = votes.values.filter { $0 >= max(0.75, total * 0.15) }.count
            let decision = winner == nil ? "undetermined" : substantial > 1 ? "mixed_dominant" : total < 1 ? "short_input" : "detected"
            // Preserve natural VAD boundaries. A language vote is not word-level code-switch alignment.
            let start = max(result.last?.endSeconds ?? 0, max(0, span.startSeconds - 0.2))
            // At a forced VAD split the next speech may start immediately. Do not give its
            // first syllable to the previous language just to add a padding margin.
            let nextSpeech = index + 1 < ordered.count ? ordered[index + 1].startSeconds : duration
            let end = min(duration, span.endSeconds + 0.2, max(span.endSeconds, nextSpeech))
            guard end > start else { continue }
            let observed = votes.keys.sorted()
            if let last = result.indices.last, winner != nil, result[last].language == winner,
               start - result[last].endSeconds <= 1.2, end - result[last].startSeconds <= 120 {
                result[last].endSeconds = end
                result[last].observedLanguages = Array(Set(result[last].observedLanguages + observed)).sorted()
                if decision == "mixed_dominant" { result[last].decision = decision }
            } else {
                result.append(LanguageRegion(startSeconds: start, endSeconds: end, language: winner,
                                             decision: decision, observedLanguages: observed))
            }
        }
        return result
    }
}
