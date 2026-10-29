import Foundation
import VoiceBenchCore

/// Persistent App data, separate from recording metadata, caches, logs and exported reports.
struct DeepSeekCredentialStore {
    private struct Document: Codable {
        var version = 1
        let apiKey: String
    }
    private let baseURL: URL?

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    private static func rootURL(_ baseURL: URL?) throws -> URL {
        if let baseURL { return baseURL }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BenchError("无法访问 App 数据目录。")
        }
        return support.appendingPathComponent("VoiceBench", isDirectory: true)
    }

    var fileURL: URL {
        get throws {
            let root = try Self.rootURL(baseURL)
            return root.appendingPathComponent("Credentials", isDirectory: true).appendingPathComponent("deepseek-api-key.json")
        }
    }

    func read() throws -> String? {
        let url = try fileURL
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw BenchError("无法读取 DeepSeek API Key 配置版本。") }
            return try DeepSeekTextCorrector.normalizedAPIKey(document.apiKey)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            // Decoding errors can contain stored values; never surface raw errors with credentials.
            throw BenchError("无法读取 App 数据目录中的 DeepSeek API Key，请在设置中重新保存。")
        }
    }

    func save(_ value: String) throws {
        let key = try DeepSeekTextCorrector.normalizedAPIKey(value)
        do {
            let url = try fileURL
            var directory = url.deletingLastPathComponent()
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let data = try JSONEncoder().encode(Document(apiKey: key))
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: url, options: .atomic)
            #endif
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw BenchError("保存 DeepSeek API Key 到 App 数据目录失败，请重试。")
        }
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: fileURL) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { throw BenchError("删除 App 数据目录中的 DeepSeek API Key 失败，请重试。") }
    }
}
