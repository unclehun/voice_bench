import Foundation
import VoiceBenchCore

struct AppleSpeechSettingsStore {
    private struct Document: Codable {
        var version = 1
        let localeIdentifier: String
    }
    private let baseURL: URL?
    init(baseURL: URL? = nil) { self.baseURL = baseURL }

    var fileURL: URL {
        get throws {
            let root: URL
            if let baseURL { root = baseURL }
            else {
                guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    throw BenchError("无法访问 App 数据目录。")
                }
                root = support.appendingPathComponent("VoiceBench", isDirectory: true)
            }
            return root.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("apple-speech.json")
        }
    }

    func load() throws -> AppleSpeechSettings {
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
            guard document.version == 1 else { throw BenchError("Apple Speech 设置版本无法读取。") }
            return try AppleSpeechSettings(localeIdentifier: document.localeIdentifier)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return AppleSpeechSettings() }
        catch { throw BenchError("无法读取 Apple Speech 默认语言，请在设置中重新选择。") }
    }

    func save(_ settings: AppleSpeechSettings) throws {
        let validated = try AppleSpeechSettings(localeIdentifier: settings.localeIdentifier)
        do {
            let url = try fileURL
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try JSONEncoder().encode(Document(localeIdentifier: validated.localeIdentifier)).write(to: url, options: .atomic)
        } catch { throw BenchError("保存 Apple Speech 默认语言失败，请重试。") }
    }
}
