import Foundation
import GitCoworkCore

struct SignInError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Network side of signing in: device flow, token check, token refresh.
enum SignIn {
    static func requestCode(kind: HostKind, host: String, clientID: String) async throws -> DeviceFlow.Code {
        guard let request = DeviceFlow.codeRequest(kind: kind, host: host, clientID: clientID) else {
            throw SignInError(message: L("\(host) isn't a valid server name."))
        }
        let (data, response) = try await send(request, host: host)
        if let code = DeviceFlow.parseCode(data) { return code }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if case .failed(let reason) = DeviceFlow.parsePoll(data), status != 404 {
            throw SignInError(message: L("\(host) refused the sign-in: \(reason)"))
        }
        throw SignInError(message: L("\(host) doesn't offer browser sign-in for this app. Check the client ID, or add an access token instead."))
    }

    /// Polls until the user approves in the browser. Cancel the task to stop.
    static func waitForToken(kind: HostKind, host: String, clientID: String, code: DeviceFlow.Code) async throws -> TokenSet {
        guard let request = DeviceFlow.tokenRequest(kind: kind, host: host, clientID: clientID, deviceCode: code.deviceCode) else {
            throw SignInError(message: L("\(host) isn't a valid server name."))
        }
        var interval = code.interval
        let deadline = Date().addingTimeInterval(code.expiresIn)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (data, _) = try await send(request, host: host)
            switch DeviceFlow.parsePoll(data) {
            case .token(let tokens): return tokens
            case .pending: continue
            case .slowDown: interval += 5
            case .denied: throw SignInError(message: L("Sign-in was declined in the browser."))
            case .expired: throw SignInError(message: L("The code expired. Start again."))
            case .failed(let reason): throw SignInError(message: L("Sign-in failed: \(reason)"))
            }
        }
        throw SignInError(message: L("The code expired. Start again."))
    }

    /// Checks a token and returns the account name it belongs to.
    static func username(kind: HostKind, host: String, token: String) async throws -> String {
        guard let request = HostAPI.currentUserRequest(kind: kind, host: host, token: token) else {
            throw SignInError(message: L("\(host) isn't a valid server name."))
        }
        let (data, response) = try await send(request, host: host)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw SignInError(message: L("\(host) didn't accept the token. Check that it's current and has the scopes \(HostAPI.tokenScopesHint(kind: kind))."))
        }
        guard (200..<300).contains(status), let name = HostAPI.parseUsername(data, kind: kind) else {
            throw SignInError(message: L("\(host) didn't answer like a \(kind.title) server (HTTP \(status)). Check the server type."))
        }
        return name
    }

    /// New tokens from a refresh token, or nil if the host said no.
    static func refresh(kind: HostKind, host: String, clientID: String, refreshToken: String) async -> TokenSet? {
        guard let request = DeviceFlow.refreshRequest(kind: kind, host: host, clientID: clientID, refreshToken: refreshToken),
              let (data, _) = try? await send(request, host: host),
              case .token(var tokens) = DeviceFlow.parsePoll(data)
        else { return nil }
        if tokens.refresh == nil { tokens.refresh = refreshToken }
        return tokens
    }

    static func send(_ request: URLRequest, host: String) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SignInError(message: L("Couldn't reach \(host): \(error.localizedDescription)"))
        }
    }
}

extension HostKind {
    var title: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .gitea: "Gitea / Forgejo"
        }
    }
}
