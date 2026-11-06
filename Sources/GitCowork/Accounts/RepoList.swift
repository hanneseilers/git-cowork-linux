import Foundation
import GitCoworkCore

/// Network side of the Clone sheet's repo list.
enum RepoList {
    /// Every repo the account can see, newest activity first, following the
    /// host's page links up to `HostAPI.maxRepoPages`.
    static func fetch(for account: HostAccount) async throws -> [HostRepo] {
        let host = account.host
        guard let tokens = await Credentials.shared.tokens(for: account) else {
            throw SignInError(message: "No token for \(host) in the Keychain. Sign in again in Settings › Accounts.")
        }
        var request = HostAPI.reposRequest(kind: account.kind, host: host, token: tokens.access)
        var repos: [HostRepo] = []
        var seen = Set<String>()
        var pages = 0
        while let r = request, pages < HostAPI.maxRepoPages {
            try Task.checkCancellation()
            let (data, response) = try await SignIn.send(r, host: host)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 401 || status == 403 {
                throw SignInError(message: "\(host) didn't accept the token. Sign in again in Settings › Accounts.")
            }
            guard (200..<300).contains(status), let page = HostAPI.parseRepos(data, kind: account.kind, host: host) else {
                throw SignInError(message: "\(host) didn't return a repository list (HTTP \(status)).")
            }
            // Offset pages can shift while we read them; keep the first copy.
            repos += page.filter { seen.insert($0.id).inserted }
            pages += 1
            request = HostAPI.nextReposRequest(linkHeader: http?.value(forHTTPHeaderField: "Link"),
                                               kind: account.kind, host: host, token: tokens.access)
        }
        return repos
    }
}
