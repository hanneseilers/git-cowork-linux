import Foundation
import GitCoworkCore
import Observation

/// Signed-in accounts, for Settings. The account list is in UserDefaults,
/// the tokens in the Keychain.
@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [HostAccount] = AccountList.load()

    func add(_ account: HostAccount, tokens: TokenSet) throws {
        guard let data = try? JSONEncoder().encode(tokens), Keychain.save(data, host: account.host) else {
            throw SignInError(message: L("Couldn't save the token in the Keychain."))
        }
        accounts.removeAll { $0.host == account.host }
        accounts.append(account)
        accounts.sort { $0.host < $1.host }
        AccountList.save(accounts)
        Credentials.shared.reload()
    }

    func signOut(_ account: HostAccount) {
        Keychain.delete(host: account.host)
        accounts.removeAll { $0.host == account.host }
        AccountList.save(accounts)
        Credentials.shared.forget(account)
        Credentials.shared.reload()
    }
}

enum AccountList {
    private static let key = "accounts"

    static func load() -> [HostAccount] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([HostAccount].self, from: data)) ?? []
    }

    static func save(_ accounts: [HostAccount]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: key)
    }
}

/// Puts tokens where git finds them: git's credential-cache daemon on a
/// private socket, plus `-c` options that point signed-in hosts at it
/// (see CredentialConfig). Used by GitRunner from any thread.
final class Credentials: @unchecked Sendable {
    static let shared = Credentials()

    /// How long the daemon keeps a token without being refilled. Every network
    /// command refills it, so this only matters after the app is gone.
    private static let cacheTimeout = 3600

    let socketPath: String
    private let lock = NSLock()
    private var accounts: [HostAccount] = AccountList.load()
    private let refresher = Refresher()

    private init() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("git-cowork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        socketPath = dir.appendingPathComponent("credentials.sock").path
    }

    private var current: [HostAccount] {
        lock.lock(); defer { lock.unlock() }
        return accounts
    }

    func reload() {
        let list = AccountList.load()
        lock.lock(); accounts = list; lock.unlock()
    }

    /// Extra `-c` options for every git command. Empty when nobody signed in.
    var configArgs: [String] {
        let hosts = current.map(\.host)
        return hosts.isEmpty ? [] : CredentialConfig.configArgs(hosts: hosts, socketPath: socketPath)
    }

    /// Fills the cache before a command that may talk to a server. Refreshes
    /// tokens that are about to expire first.
    func prepare(gitPath: String, env: [String: String]) async {
        for account in current {
            guard let tokens = await refresher.validTokens(for: account),
                  let input = CredentialConfig.storeInput(host: account.host, username: account.gitUsername, password: tokens.access)
            else { continue }
            cache(["store"], input: input, gitPath: gitPath, env: env)
        }
    }

    /// Drops a host's token from the running daemon.
    func forget(_ account: HostAccount) {
        let input = Data("protocol=https\nhost=\(account.host)\n\n".utf8)
        cache(["erase"], input: input, gitPath: GitRunner.shared.gitPath, env: ProcessInfo.processInfo.environment)
    }

    /// Stops the daemon so no token outlives the app.
    func stop() {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        cache(["exit"], input: Data(), gitPath: GitRunner.shared.gitPath, env: ProcessInfo.processInfo.environment)
    }

    private func cache(_ action: [String], input: Data, gitPath: String, env: [String: String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = ["credential-cache", "--socket", socketPath, "--timeout", String(Self.cacheTimeout)] + action
        p.environment = env
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        try? inPipe.fileHandleForWriting.write(contentsOf: input)
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
    }
}

/// Reads tokens from the Keychain and renews expiring ones, one refresh per
/// host at a time (GitLab replaces the refresh token on every use, so two
/// refreshes at once would leave one of them holding a dead token).
private actor Refresher {
    private var running: [String: Task<TokenSet?, Never>] = [:]

    func validTokens(for account: HostAccount) async -> TokenSet? {
        if let task = running[account.host] { return await task.value }
        guard let data = Keychain.load(host: account.host),
              let tokens = try? JSONDecoder().decode(TokenSet.self, from: data)
        else { return nil }
        guard tokens.expiresSoon(), let refreshToken = tokens.refresh,
              let clientID = OAuthApps.clientID(for: account.host)
        else { return tokens }

        let task = Task<TokenSet?, Never> {
            guard let fresh = await SignIn.refresh(kind: account.kind, host: account.host,
                                                   clientID: clientID, refreshToken: refreshToken)
            else { return tokens }   // let git try; an auth error tells the user to sign in again
            if let data = try? JSONEncoder().encode(fresh) { Keychain.save(data, host: account.host) }
            return fresh
        }
        running[account.host] = task
        let result = await task.value
        running[account.host] = nil
        return result
    }
}
