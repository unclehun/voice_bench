import Foundation

public struct RunEvaluation: Codable, Sendable {
    public let runID: UUID
    public let rawCER: CER?
    public let correctedCER: CER?
    public let deltaCER: Double?
    public let rtf: Double?
}

public struct Report: Codable, Sendable {
    public var schemaVersion = 1
    public var exportedAt = Date()
    public var normalizationVersion = Evaluation.normalizationVersion
    public var environment: [String: String]
    public var recording: Recording
    public var evaluation: [RunEvaluation]
    public init(recording: Recording, environment: [String: String]) {
        self.recording = recording; self.environment = environment
        evaluation = recording.runs.map { run in
            let hasReference = !recording.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let raw = hasReference && run.status == .completed ? Evaluation.cer(reference: recording.reference, hypothesis: run.rawText) : nil
            let corrected = hasReference ? run.correction.text.map { Evaluation.cer(reference: recording.reference, hypothesis: $0) } : nil
            let delta: Double?
            if let a = raw?.rate, let b = corrected?.rate { delta = b - a } else { delta = nil }
            return RunEvaluation(runID: run.id, rawCER: raw, correctedCER: corrected, deltaCER: delta, rtf: run.rtf(duration: recording.duration))
        }
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        // Explicit nulls distinguish unavailable measurements from numeric zero or copied text.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if var recording = object["recording"] as? [String: Any], var runs = recording["runs"] as? [[String: Any]] {
            for index in runs.indices {
                for key in ["preparationMS", "transcriptionMS", "error"] where runs[index][key] == nil { runs[index][key] = NSNull() }
                if var correction = runs[index]["correction"] as? [String: Any] {
                    for key in ["text", "elapsedMS", "promptHash", "error"] where correction[key] == nil { correction[key] = NSNull() }
                    runs[index]["correction"] = correction
                }
            }
            recording["runs"] = runs; object["recording"] = recording
        }
        if var metrics = object["evaluation"] as? [[String: Any]] {
            for index in metrics.indices {
                for key in ["rawCER", "correctedCER", "deltaCER", "rtf"] where metrics[index][key] == nil { metrics[index][key] = NSNull() }
                for key in ["rawCER", "correctedCER"] {
                    if var value = metrics[index][key] as? [String: Any] {
                        let measured = key == "rawCER" ? evaluation[index].rawCER?.rate : evaluation[index].correctedCER?.rate
                        value["rate"] = measured.map { $0 as Any } ?? NSNull()
                        metrics[index][key] = value
                    }
                }
            }
            object["evaluation"] = metrics
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
    public func markdown() -> String {
        var lines = ["# 语音识别对比报告", "", "音频：\(recording.name)", "", "SHA-256：\(recording.sha256)",
                     "", "时长：\(String(format: "%.2f", recording.duration)) 秒", "", "规范化：\(normalizationVersion)", ""]
        for key in environment.keys.sorted() { lines.append("- \(key)：\(environment[key]!)") }
        for (run, metric) in zip(recording.runs, evaluation) {
            lines += ["", "## \(run.engine.title) · \(run.status.rawValue)", "", "运行 ID：\(run.id)",
                      "", "初始化：\(format(run.preparationMS)) ms；转写：\(format(run.transcriptionMS)) ms；RTF：\(format(metric.rtf))",
                      "", "原文 CER：\(format(metric.rawCER?.rate))；纠错 CER：\(format(metric.correctedCER?.rate))；ΔCER：\(format(metric.deltaCER))",
                      "", "原始文字：", "", run.rawText, "", "纠错状态：\(run.correction.status)"]
            if let corrected = run.correction.text { lines += ["", "纠错文字：", "", corrected] }
            if let error = run.error { lines += ["", "错误：\(error)"] }
            if let error = run.correction.error { lines += ["", "纠错错误：\(error)"] }
        }
        lines += ["", "## 人工参考稿", "", recording.reference, "", "详细配置、分段与模型信息见配套 JSON。", ""]
        return lines.joined(separator: "\n")
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.4f", $0) } ?? "未测 / 不适用" }
}
