import Foundation
import Darwin
import VoiceBenchCore

/// All app-created disposable files live in one private sandbox directory.
struct AppTemporaryFiles: Sendable {
    static let live = AppTemporaryFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBench", isDirectory: true))
    let root: URL

    /// All derived audio and report staging for one recording have the same deletion boundary.
    func workspace(recordingID: UUID) -> AppTemporaryFiles {
        AppTemporaryFiles(root: root.appendingPathComponent("Recording-" + recordingID.uuidString, isDirectory: true))
    }

    func removeWorkspaceIfEmpty(recordingID: UUID) throws {
        let folder = workspace(recordingID: recordingID).root
        try validateRemoval(folder)
        if try AppFileSystem.isSymbolicLink(folder) { try remove(folder); return }
        if try AppFileSystem.exists(folder),
           try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty { try remove(folder) }
    }

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
        try validateRemoval(url)
        try AppFileSystem.removeIfPresent(url)
    }

    private func validateRemoval(_ url: URL) throws {
        // A substituted root symlink must not turn an external directory into an allowed root.
        guard try !AppFileSystem.isSymbolicLink(root) else {
            throw BenchError("App 临时根目录被替换为符号链接，请重新启动 App 后重试。")
        }
        let base = try AppFileSystem.physicalComponents(root)
        if try AppFileSystem.isSymbolicLink(url) {
            // Unlinking an owned final entry is safe, even when its destination is missing/outside.
            // Validate the physical parent; removeIfPresent never traverses this final link.
            let parent = try AppFileSystem.physicalComponents(url.deletingLastPathComponent())
            guard parent.count >= base.count, parent.starts(with: base) else {
                throw BenchError("拒绝清理 App 临时目录以外的文件。")
            }
            return
        }
        let target = try AppFileSystem.physicalComponents(url)
        guard target.count > base.count, target.starts(with: base) else {
            throw BenchError("拒绝清理 App 临时目录以外的文件。")
        }
    }

    /// Call only at cold launch or while all recording, inference and sharing are idle.
    func reset() throws {
        let manager = FileManager.default
        // lstat also finds dangling symlinks, which fileExists would leave behind.
        try AppFileSystem.removeIfPresent(root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Migrate only recognizable files from v0.1's flat tmp layout, never external inputs.
    static func removeLegacyFiles(in directory: URL) throws {
        guard try AppFileSystem.exists(directory) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let isReport = name.hasPrefix("Report-") && UUID(uuidString: String(name.dropFirst(7))) != nil
            let isAudio = url.pathExtension == "caf" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            let isRecording = name.hasPrefix("录音-") && url.pathExtension == "m4a"
            if isReport || isAudio || isRecording { try AppFileSystem.removeIfPresent(url) }
        }
    }
}

/// Uses physical POSIX paths consistently; Foundation can drop /private only for existing URLs.
/// Missing descendants are resolved from their nearest existing ancestor, not by string aliases.
enum AppFileSystem {
    static func physicalComponents(_ url: URL) throws -> [String] {
        var path = try filePath(url)
        var missing: [String] = []
        while true {
            if let resolved = path.withCString({ realpath($0, nil) }) {
                defer { free(resolved) }
                var components = (String(cString: resolved) as NSString).pathComponents
                for component in missing.reversed() {
                    if component == "." { continue }
                    if component == ".." {
                        if components.count > 1 { components.removeLast() }
                    } else { components.append(component) }
                }
                return components
            }
            let code = errno
            guard code == ENOENT else { throw posixError(code) }
            // A broken symlink is an existing entry, not a safely missing path. Do not follow it.
            if try exists(URL(fileURLWithPath: path)) {
                throw BenchError("清理路径含有无法解析的符号链接，请清除全部数据或重启后重试。")
            }
            let component = (path as NSString).lastPathComponent
            let parent = (path as NSString).deletingLastPathComponent
            guard !component.isEmpty, parent != path else { throw posixError(code) }
            missing.append(component)
            path = parent
        }
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if try filePath(url).withCString({ lstat($0, &info) }) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw posixError(code)
    }

    static func isSymbolicLink(_ url: URL) throws -> Bool {
        var info = stat()
        if try filePath(url).withCString({ lstat($0, &info) }) == 0 { return (info.st_mode & S_IFMT) == S_IFLNK }
        let code = errno
        if code == ENOENT { return false }
        throw posixError(code)
    }

    /// Caller owns/has validated the path. FileManager unlinks symlinks without deleting their targets.
    static func removeIfPresent(_ url: URL) throws {
        guard try exists(url) else { return }
        do { try FileManager.default.removeItem(atPath: filePath(url)) }
        catch {
            // The OS may purge a temporary item after lstat. Ignore only a confirmed missing item.
            if try !exists(url) { return }
            throw error
        }
    }

    private static func filePath(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
            throw BenchError("清理路径必须是有效的本机文件路径。")
        }
        var path = url.path
        // A trailing slash makes lstat follow a final directory symlink; inspect/unlink its entry.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func posixError(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
}
