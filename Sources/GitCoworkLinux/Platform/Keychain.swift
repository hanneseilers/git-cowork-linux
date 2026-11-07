import CGtk
import Foundation

/// Tokens in the desktop's Secret Service (GNOME Keyring, KWallet, KeePassXC),
/// one item per host. Linux counterpart of the macOS Keychain wrapper, with
/// the same calls. Nothing is ever written to a plain file: without a Secret
/// Service, saving fails and Settings says why.
enum Keychain {
    static let service = "git-cowork"
    /// Passphrases of SSH keys made under Settings › Accounts (account: key path).
    static let sshService = "git-cowork-ssh"

    /// Last error from the Secret Service, for the UI.
    nonisolated(unsafe) private(set) static var lastError: String?

    @discardableResult
    static func save(_ data: Data, host: String) -> Bool {
        store(data.base64EncodedString(), service: service, account: host, label: "git-cowork: \(host)")
    }

    static func load(host: String) -> Data? {
        lookup(service: service, account: host).flatMap { Data(base64Encoded: $0) }
    }

    static func delete(host: String) {
        clear(service: service, account: host)
    }

    // MARK: Text secrets

    @discardableResult
    static func store(_ secret: String, service: String, account: String, label: String) -> Bool {
        var message: UnsafeMutablePointer<CChar>?
        let ok = gc_secret_store(service, account, label, secret, &message) == 1
        if let message {
            lastError = String(cString: message)
            g_free(message)
        } else if ok {
            lastError = nil
        }
        return ok
    }

    static func lookup(service: String, account: String) -> String? {
        guard let value = gc_secret_lookup(service, account) else { return nil }
        defer { secret_password_free(value) }
        return String(cString: value)
    }

    static func clear(service: String, account: String) {
        _ = gc_secret_clear(service, account)
    }
}
