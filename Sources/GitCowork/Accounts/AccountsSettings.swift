import AppKit
import GitCoworkCore
import SwiftUI

/// Settings > Accounts: signed-in servers, sign in, add a token.
struct AccountsSection: View {
    private enum SheetKind: Identifiable {
        case browser(HostKind), token
        var id: String {
            switch self {
            case .browser(let kind): "browser-\(kind.rawValue)"
            case .token: "token"
            }
        }
    }

    @State private var sheet: SheetKind?
    private let store = AccountStore.shared

    var body: some View {
        Section("Accounts") {
            ForEach(store.accounts) { account in
                LabeledContent {
                    Button("Sign Out") { store.signOut(account) }
                } label: {
                    Text(account.username)
                    Text("\(account.kind.title) · \(account.host)")
                }
            }
            HStack {
                Button("Sign In to GitHub…") { sheet = .browser(.github) }
                Button("Sign In to GitLab…") { sheet = .browser(.gitlab) }
                Spacer()
                Button("Add Token…") { sheet = .token }
            }
            Text("Used for HTTPS remotes on these servers, and only by git-cowork. Git in the terminal, SSH remotes and other servers keep your own setup. Tokens are kept in the Keychain.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .browser(let host): BrowserSignInSheet(kind: host)
            case .token: TokenSheet()
            }
        }
    }
}

private func defaultHost(_ kind: HostKind) -> String {
    switch kind {
    case .github: "github.com"
    case .gitlab: "gitlab.com"
    case .gitea: "codeberg.org"
    }
}

/// Same frame as SheetScaffold, but stays open while sign-in runs.
private struct AccountSheetFrame<Content: View, Buttons: View>: View {
    let title: String
    let error: String?
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(ui: title).font(Theme.Font.title)
            content
            if let error {
                Text(error).font(Theme.Font.small).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.m) {
                Spacer()
                buttons
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 440)
    }
}

/// Device flow: show a code, the user approves it in the browser, done.
struct BrowserSignInSheet: View {
    let kind: HostKind
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var clientID = ""
    @State private var code: DeviceFlow.Code?
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private static let codeFont = Font.system(size: 26, weight: .semibold, design: .monospaced)

    init(kind: HostKind) {
        self.kind = kind
        _host = State(initialValue: defaultHost(kind))
    }

    private var normalizedHost: String? { HostAccount.normalizeHost(host) }
    private var knownClientID: String? { normalizedHost.flatMap(OAuthApps.clientID(for:)) }
    private var trimmedClientID: String { clientID.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        AccountSheetFrame(title: String(localized: "Sign In to \(kind.title)"), error: error) {
            if let code {
                Text("Enter this code on \(code.verificationURL.host ?? host) and approve git-cowork:")
                Text(code.userCode).font(Self.codeFont).textSelection(.enabled)
                Button("Copy Code and Open Browser") { openBrowser(code) }
                HStack(spacing: Theme.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(Theme.Font.small).foregroundStyle(.secondary)
                }
            } else {
                TextField("Server", text: $host).textFieldStyle(.roundedBorder)
                if knownClientID == nil {
                    TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder)
                    Text(clientIDHelp).font(Theme.Font.small).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("You approve git-cowork in your browser. No password is typed here.")
                    .font(Theme.Font.small).foregroundStyle(.secondary)
            }
        } buttons: {
            Button("Cancel") { task?.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
            if code == nil {
                Button("Continue") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || normalizedHost == nil || (knownClientID == nil && trimmedClientID.isEmpty))
            }
        }
        .onDisappear { task?.cancel() }
    }

    private var clientIDHelp: String {
        switch kind {
        case .github: L("Register an OAuth app under Settings > Developer settings > OAuth Apps on that server, tick \"Enable Device Flow\", and paste its client ID. Or use Add Token instead.")
        default: L("Add an application under User settings > Applications on that server (GitLab 17.3 or later): untick \"Confidential\", allow the device code grant, scopes read_user, read_api and write_repository. Paste its application ID. Or use Add Token instead.")
        }
    }

    private func start() {
        guard let host = normalizedHost, let id = knownClientID ?? (trimmedClientID.isEmpty ? nil : trimmedClientID) else { return }
        let enteredID = knownClientID == nil
        error = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                let code = try await SignIn.requestCode(kind: kind, host: host, clientID: id)
                self.code = code
                openBrowser(code)
                let tokens = try await SignIn.waitForToken(kind: kind, host: host, clientID: id, code: code)
                let name = try await SignIn.username(kind: kind, host: host, token: tokens.access)
                if enteredID { OAuthApps.save(id, for: host) }
                try AccountStore.shared.add(HostAccount(host: host, kind: kind, username: name, method: .oauth), tokens: tokens)
                dismiss()
            } catch is CancellationError {
            } catch {
                self.code = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func openBrowser(_ code: DeviceFlow.Code) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        NSWorkspace.shared.open(code.verificationURLComplete ?? code.verificationURL)
    }
}

/// Personal access token, for Gitea/Forgejo, older GitLab servers, or anyone
/// who prefers it.
struct TokenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: HostKind = .github
    @State private var host = defaultHost(.github)
    @State private var token = ""
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var normalizedHost: String? { HostAccount.normalizeHost(host) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        AccountSheetFrame(title: "Add Access Token", error: error) {
            Picker("Server type", selection: $kind) {
                ForEach(HostKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: kind) { old, new in
                if host == defaultHost(old) { host = defaultHost(new) }
            }
            TextField("Server", text: $host).textFieldStyle(.roundedBorder)
            SecureField("Token", text: $token).textFieldStyle(.roundedBorder)
            HStack(spacing: Theme.Space.s) {
                Text("Needs the scopes \(kind.scopesHint).")
                if let host = normalizedHost, let page = HostAPI.newTokenPage(kind: kind, host: host) {
                    Link("Create one…", destination: page)
                }
            }
            .font(Theme.Font.small).foregroundStyle(.secondary)
        } buttons: {
            Button("Cancel") { task?.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(working || normalizedHost == nil || trimmedToken.isEmpty)
        }
        .onDisappear { task?.cancel() }
    }

    private func add() {
        guard let host = normalizedHost else { return }
        let token = trimmedToken, kind = kind
        error = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                let name = try await SignIn.username(kind: kind, host: host, token: token)
                try AccountStore.shared.add(HostAccount(host: host, kind: kind, username: name, method: .token),
                                            tokens: TokenSet(access: token))
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
