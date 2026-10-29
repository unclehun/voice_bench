import Foundation
import VoiceBenchCore

/// Real temporary files; no personal credentials or remote API calls.
@main
struct CredentialChecks {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw BenchError("Credential check failed: \(message)") }
    }

    static func expectFailure(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw BenchError("Credential check failed: \(message)")
    }

    static func main() async throws {
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("VoiceBench-Credentials-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let key = "sk-synthetic-persistent-key"
        let root = fixture.appendingPathComponent("ApplicationSupport/VoiceBench", isDirectory: true)
        let store = DeepSeekCredentialStore(baseURL: root)
        let file = try store.fileURL
        try check(file == root.appendingPathComponent("Credentials/deepseek-api-key.json"), "stable Application Support path")
        let productionPath = try DeepSeekCredentialStore().fileURL.path
        try check(productionPath.hasSuffix("/Library/Application Support/VoiceBench/Credentials/deepseek-api-key.json"), "production uses persistent App directory")
        try check(try store.read() == nil && !manager.fileExists(atPath: root.path), "missing configuration reads empty without creating files")
        try store.save(" \(key)\n")
        try check(manager.fileExists(atPath: file.path), "save writes a real configuration file")
        try check(try store.read() == key, "read normalized saved key")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try check(Set(document.keys) == Set(["version", "apiKey"]) && document["apiKey"] as? String == key, "configuration contains only schema version and API key")
        let permissions = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "secret file is owner-only")
        let directoryPermissions = try manager.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        try check(directoryPermissions?.intValue == 0o700, "credentials directory is owner-only")

        // Fresh instances simulate restart and replacement code using the same App data directory.
        let relaunched = DeepSeekCredentialStore(baseURL: root)
        try check(try relaunched.read() == key, "cold launch reads the stored file")
        let updated = DeepSeekCredentialStore(baseURL: root)
        try check(try updated.read() == key, "replacement App instance reuses persistent data")
        let oldData = try Data(contentsOf: file)
        try expectFailure({ try updated.save("sk-bad\nheader") }, "invalid key must be rejected")
        try check(try Data(contentsOf: file) == oldData, "invalid save preserves the existing file")
        try updated.save("sk-synthetic-replacement")
        try check(try relaunched.read() == "sk-synthetic-replacement", "replacement key is read from disk")
        try check(try manager.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent], "atomic save leaves no temporary credential copies")
        try check(try manager.contentsOfDirectory(atPath: root.deletingLastPathComponent().path) == ["VoiceBench"], "saving creates no extra state outside App data")
        try updated.remove()
        try check(try relaunched.read() == nil && !manager.fileExists(atPath: file.path), "deleting configuration clears all instances")
        try updated.remove()
        try check(try DeepSeekCredentialStore(baseURL: root).read() == nil, "repeated deletion and restart stay unconfigured")

        let blockedRoot = fixture.appendingPathComponent("Blocked", isDirectory: true)
        try manager.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedRoot.appendingPathComponent("Credentials"))
        let blocked = DeepSeekCredentialStore(baseURL: blockedRoot)
        try expectFailure({ try blocked.save(key) }, "filesystem write failure must be reported")

        try updated.save(key)
        try Data("{invalid secret: \(key)}".utf8).write(to: file)
        do { _ = try updated.read(); throw BenchError("Corrupt configuration accepted") }
        catch {
            try check(!error.localizedDescription.contains(key), "corrupt configuration cannot expose key in errors")
            try check(error.localizedDescription.contains("重新保存"), "corrupt configuration is actionable")
        }
        try updated.save(key)
        try check(try updated.read() == key, "saving repairs corrupt configuration")

        // Removing the complete App data container removes the only copy of its configuration.
        let container = fixture.appendingPathComponent("UninstalledApp", isDirectory: true)
        let uninstallRoot = container.appendingPathComponent("Library/Application Support/VoiceBench", isDirectory: true)
        let installed = DeepSeekCredentialStore(baseURL: uninstallRoot)
        try installed.save(key)
        let installedFile = try installed.fileURL
        try manager.removeItem(at: container)
        try check(!manager.fileExists(atPath: installedFile.path), "deleting App container removes API key configuration")
        let reinstalled = DeepSeekCredentialStore(baseURL: uninstallRoot)
        try check(try reinstalled.read() == nil && !manager.fileExists(atPath: container.path), "fresh install cannot restore deleted configuration")
        try manager.createDirectory(at: uninstallRoot, withIntermediateDirectories: true)
        try check(try DeepSeekCredentialStore(baseURL: uninstallRoot).read() == nil, "second launch after reinstall still has no key")

        // Exercise the real operation used by Settings to clear all App data.
        let appRoot = fixture.appendingPathComponent("ClearAll/ApplicationSupport/VoiceBench", isDirectory: true)
        let clearCredentials = DeepSeekCredentialStore(baseURL: appRoot)
        try clearCredentials.save(key)
        let local = try LocalStore(baseURL: appRoot,
                                  temporaryFiles: AppTemporaryFiles(root: fixture.appendingPathComponent("ClearAll/Temporary")),
                                  documentsURL: fixture.appendingPathComponent("ClearAll/Documents"))
        try clearCredentials.remove()
        try await local.removeAllData()
        try check(!manager.fileExists(atPath: clearCredentials.fileURL.path), "real clear all removes API key configuration")
        try check(try clearCredentials.read() == nil && DeepSeekCredentialStore(baseURL: appRoot).read() == nil, "status refresh and restart after clear all remain empty")
        try check(try manager.contentsOfDirectory(atPath: appRoot.path).sorted() == ["Audio", "FunASRModels", "LanguageIDModels", "Models", "QwenModels", "Records"], "clear all leaves no credential files or directory")
        try clearCredentials.save(key)
        try await local.removeAllData()
        try check(try clearCredentials.read() == nil, "full data root removal also deletes configuration independently")
        try await local.removeAllData()
        try check(try clearCredentials.read() == nil, "repeated clear all stays empty")
        print("PASS: \(checks) configuration file checks (real files, simulated restart/update/delete, actual full data clear; no real secrets used).")
    }
}
