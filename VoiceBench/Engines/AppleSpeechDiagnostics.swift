import Foundation
import OSLog

struct AppleSpeechFailure: LocalizedError, Sendable {
    let stage: String
    let summary: String
    let configuration: [String: String]
    var errorDescription: String? {
        let titles = ["check_support": "检查设备支持", "check_assets": "检查语言资源", "check_language_plan": "校验语言检测结果", "select_format": "选择音频格式",
                      "prepare_analyzer": "准备识别器", "inspect_source": "读取源录音", "convert_audio": "转换音频",
                      "open_pcm": "打开派生音频", "read_audio": "逐块读取音频", "analyze_audio": "分析音频",
                      "receive_results": "接收识别结果", "finalize_analysis": "结束分析", "collect_results": "收集最终结果",
                      "cleanup_audio": "清理临时音频"]
        return "Apple Speech 在\(titles[stage] ?? stage)阶段失败（\(stage)）：\(summary)"
    }
}

/// Metadata only: never pass audio samples or recognized text to this collector.
/// Full error descriptions stay in the app's report; unified logs expose only stages and error codes.
final class AppleSpeechDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.voicebench.demo", category: "AppleSpeech")
    private let runID: String
    private let started = ProcessInfo.processInfo.systemUptime
    private var values: [String: String]
    private var events: [String] = []
    private var firstFailure: (stage: String, summary: String, cancelled: Bool)?
    private var failureDetails: [String: String] = [:]

    init(runID: UUID) {
        self.runID = runID.uuidString
        values = ["apple_diagnostic_version": "1", "apple_run_id": runID.uuidString,
                  "apple_input_pipeline": "pcm_chunks_v1", "module": "SpeechTranscriber",
                  "offline": "true", "results": "final_only"]
    }

    func record(_ metadata: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        values.merge(metadata) { _, new in new }
    }

    func event(_ stage: String, metadata: [String: String] = [:]) {
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        lock.lock()
        values.merge(metadata) { _, new in new }
        values["apple_stage"] = stage
        // Fixed bound, including periodic chunk progress for long recordings.
        if events.count == 64 { events.removeFirst() }
        events.append("\(elapsed)ms:\(stage)")
        lock.unlock()
        let detail = metadata.keys.sorted().map { "\($0)=\(metadata[$0]!)" }.joined(separator: " ")
        logger.notice("VoiceBenchAppleSpeech run=\(self.runID, privacy: .public) stage=\(stage, privacy: .public) \(detail, privacy: .public)")
    }

    func failure(_ error: Error, stage: String) {
        let nsError = error as NSError
        let details = Self.errorDetails(error)
        let summary = "\(nsError.domain) code=\(nsError.code)"
        let cancelled = error is CancellationError
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        lock.lock()
        // Speech may propagate CancellationError to results before its concrete input error arrives.
        // Prefer that concrete failure; cleanup errors never replace an earlier cancellation.
        if firstFailure == nil || (firstFailure!.cancelled && !cancelled && stage != "cleanup_audio") {
            firstFailure = (stage, Self.bounded(nsError.localizedDescription), cancelled)
            failureDetails = details
            values["apple_error_stage"] = stage
            values["apple_error_elapsed_ms"] = String(elapsed)
        }
        // Keep all failing stages, since the same error can propagate to the result stream.
        let shouldLog = values["apple_error_at_\(stage)"] == nil
        values["apple_error_at_\(stage)"] = summary
        if shouldLog {
            if events.count == 64 { events.removeFirst() }
            events.append("\(elapsed)ms:failed:\(stage)")
        }
        lock.unlock()
        if shouldLog {
            logger.error("VoiceBenchAppleSpeech run=\(self.runID, privacy: .public) failed_stage=\(stage, privacy: .public) error=\(summary, privacy: .public)")
        }
    }

    func configuration() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var result = values
        result.merge(failureDetails) { _, new in new }
        result["apple_stage_events"] = events.joined(separator: " | ")
        return result
    }

    func wrappedFailure(_ error: Error, stage: String) -> AppleSpeechFailure {
        failure(error, stage: stage)
        lock.lock()
        let first = firstFailure!
        lock.unlock()
        return AppleSpeechFailure(stage: first.stage, summary: first.summary, configuration: configuration())
    }

    private static func errorDetails(_ error: Error) -> [String: String] {
        var result = ["apple_error_swift_type": String(reflecting: type(of: error)),
                      "apple_error_reflection": bounded(String(reflecting: error))]
        var visited = Set<ObjectIdentifier>()
        func visit(_ value: NSError, prefix: String, depth: Int) {
            guard depth < 5, visited.insert(ObjectIdentifier(value)).inserted else { return }
            result[prefix + "domain"] = value.domain
            result[prefix + "code"] = String(value.code)
            result[prefix + "description"] = bounded(value.localizedDescription)
            result[prefix + "user_info_keys"] = value.userInfo.keys.sorted().joined(separator: ",")
            for key in value.userInfo.keys.sorted().prefix(16) {
                guard let item = value.userInfo[key] else { continue }
                if let underlying = item as? NSError {
                    visit(underlying, prefix: prefix + "underlying.", depth: depth + 1)
                } else if let data = item as? Data {
                    result[prefix + "user_info." + key] = "<\(data.count) bytes>"
                } else {
                    result[prefix + "user_info." + key] = bounded(String(reflecting: item))
                }
            }
        }
        visit(error as NSError, prefix: "apple_error_", depth: 0)
        return result
    }

    private static func bounded(_ text: String) -> String {
        String(text.prefix(2048)) + (text.count > 2048 ? "…<truncated>" : "")
    }
}
