import Foundation
import Observation

/// User-selected local settings storage. No Keychain or system-password access.
@Observable @MainActor
final class CredentialsStore {
    private var keys: [String: String] = [:]
    private let fileURL: URL
    init() {
        fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper", isDirectory: true).appendingPathComponent("api-keys.json")
        // An unreadable file leaves every key empty, so the settings show them as not yet entered.
        if let data = try? Data(contentsOf: fileURL) { keys = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:] }
    }
    func read(_ provider: Provider) -> String { read(id: provider.rawValue) }
    /// Non-speech credentials (e.g. the DeepSeek text model) share the same file under their own id.
    func contains(id: String) -> Bool { !(keys[id] ?? "").isEmpty }
    func read(id: String) -> String { keys[id] ?? "" }
    func save(_ value: String, id: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = keys
        if value.isEmpty { updated.removeValue(forKey: id) }
        else { updated[id] = value }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(updated)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        keys = updated
    }
}
