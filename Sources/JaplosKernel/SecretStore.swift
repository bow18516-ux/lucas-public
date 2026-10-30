import Foundation
import Security

/// Stores secrets (currently the model API key) outside SQLite.
///
/// - Signed builds (Developer ID / Apple Development) use the Keychain.
/// - Unsigned development binaries and tests use a 0600 JSON file, because
///   Keychain ACLs are tied to a code signature and would prompt on every
///   rebuild. Force either backend with `LUCAS_SECRET_BACKEND=keychain|file`.
public final class SecretStore {
    public enum Backend: String {
        case keychain
        case file
    }

    public let home: URL
    public let backend: Backend

    private let service = "com.lucas.app.secrets"
    private let lock = NSLock()
    private var fileURL: URL { home.appendingPathComponent("secrets.json") }

    public init(home: URL) {
        self.home = home
        switch ProcessInfo.processInfo.environment["LUCAS_SECRET_BACKEND"] {
        case "file":
            backend = .file
        case "keychain":
            backend = .keychain
        default:
            backend = Self.isSignedWithTeamIdentifier() ? .keychain : .file
        }
    }

    // MARK: - Public API

    public func secret(for account: String) -> String? {
        switch backend {
        case .keychain:
            if let value = keychainGet(account) { return value }
            return fileGet(account)
        case .file:
            return fileGet(account)
        }
    }

    public func setSecret(_ value: String, for account: String) throws {
        switch backend {
        case .keychain:
            do {
                try keychainSet(value, account: account)
                try? fileRemove(account)
            } catch {
                // Keychain may be unavailable in unsigned builds, CI, or
                // sandboxed processes. Keep the app usable with a 0600 file.
                FileHandle.standardError.write(Data(
                    "lucasd: Keychain unavailable (\(error)); falling back to 0600 secrets file\n".utf8
                ))
                try fileSet(value, account: account)
            }
        case .file:
            try fileSet(value, account: account)
        }
    }

    public func removeSecret(for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? fileRemove(account)
    }

    // MARK: - Keychain

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func keychainGet(_ account: String) -> String? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainSet(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = keychainQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretStoreError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw SecretStoreError.keychain(updateStatus)
        }
    }

    // MARK: - File fallback

    private func loadFile() -> [String: String] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    private func fileGet(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadFile()[account]
    }

    private func fileSet(_ value: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var contents = loadFile()
        contents[account] = value
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func fileRemove(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var contents = loadFile()
        contents.removeValue(forKey: account)
        let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Signature detection

    /// Returns true when the current executable carries a team identifier,
    /// i.e. it is a normally signed app/daemon rather than a local dev build.
    private static func isSignedWithTeamIdentifier() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return false
        }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard
            SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
            let dictionary = information as? [String: Any]
        else { return false }

        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
    }
}

public enum SecretStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .keychain(let status):
            return "Keychain error \(status)"
        }
    }
}
