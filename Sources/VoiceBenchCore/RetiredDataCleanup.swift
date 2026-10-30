import Foundation

/// Upgrade-only deletion rules. Retired engines are never exposed as runnable models.
public enum RetiredDataCleanup {
    public static let internalDirectories = ["LanguageIDModels", "QwenModels", "FunASRModels", "WhisperTurboModels"]
    public static let sourceDirectories = ["WhisperTiny_INT8", "Qwen3ASR_0_6B_INT8", "FunASR_MLT_Nano_INT8", "WhisperLargeV3Turbo_INT8"]

    /// Filter before decoding EngineID so recordings from older versions remain readable.
    /// Original audio, user text and retained runs/corrections are preserved.
    public static func cleanRecording(_ data: Data) throws -> Data? {
        guard var recording = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = recording["runs"] as? [[String: Any]] else {
            throw BenchError("旧录音数据格式无效，未修改该文件。")
        }
        let allowed = Set(EngineID.allCases.map(\.rawValue))
        var changed = false
        var retained: [[String: Any]] = []
        for var run in runs {
            guard let engine = run["engine"] as? String, allowed.contains(engine) else {
                changed = true
                continue
            }
            if run.removeValue(forKey: "languageDetection") != nil { changed = true }
            if let configuration = run["configuration"] as? [String: Any] {
                let cleaned = configuration.filter { key, value in
                    let name = key.lowercased()
                    return !name.contains("whisper") && !name.hasPrefix("lid_")
                        && !name.hasPrefix("language_detection") && !name.hasPrefix("language_plan")
                        && !String(describing: value).lowercased().contains("whisper-tiny")
                }
                if cleaned.count != configuration.count { run["configuration"] = cleaned; changed = true }
            }
            retained.append(run)
        }
        guard changed else { return nil }
        recording["runs"] = retained
        recording["revision"] = (recording["revision"] as? Int ?? 0) + 1
        return try JSONSerialization.data(withJSONObject: recording, options: [.prettyPrinted, .sortedKeys])
    }
}
