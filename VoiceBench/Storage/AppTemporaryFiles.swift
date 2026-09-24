import Foundation
import VoiceBenchCore

/// All app-created disposable files live in one private sandbox directory.
struct AppTemporaryFiles: Sendable {
    static let live = AppTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBench", isDirectory: true))
    let root: URL

    func file(extension ext: String, prefix: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(prefix + UUID().uuidString).appendingPathExtension(ext)
    }

    func directory(prefix: String) throws -> URL {
        let folder = try file(extension: "", prefix: prefix)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func remove(_ url: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else {
            throw BenchError("拒绝清理 App 临时目录以外的文件。")
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Call only at cold launch or while all recording, inference and sharing are idle.
    func reset() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Migrate only recognizable files from v0.1's flat tmp layout, never external inputs.
    static func removeLegacyFiles(in directory: URL) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let isReport = name.hasPrefix("Report-") && UUID(uuidString: String(name.dropFirst(7))) != nil
            let isAudio = url.pathExtension == "caf" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            let isRecording = name.hasPrefix("录音-") && url.pathExtension == "m4a"
            if isReport || isAudio || isRecording { try FileManager.default.removeItem(at: url) }
        }
    }
}
