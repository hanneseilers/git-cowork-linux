import AppKit
import GitCoworkCore
import SwiftUI

/// Settings > Accounts: signed-in servers, sign in, add a token, SSH keys.
struct AccountsSection: View {
    private enum SheetKind: Identifiable {
        case browser(HostKind, host: String?), token
        case createKey(HostAccount), hostEntry(HostAccount)
        var id: String {
            switch self {
            case .browser(let kind, let host): "browser-\(kind.rawValue)-\(host ?? "")"
            case .token: "token"
            case .createKey(let account): "key-\(account.host)"
            case .hostEntry(let account): "entry-\(account.host)"
            }
        }
    }

    @State private var sheet: SheetKind?
    private let store = AccountStore.shared

    var body: some View {
        Section("Accounts") {
            ForEach(store.accounts) { account in
                LabeledContent {
                    HStack(spacing: Theme.Space.m) {
                        if account.sshKey != nil {
                            Button("SSH Host Entry…") { sheet = .hostEntry(account) }
                        } else if account.canAddSSHKey {
                            Button("Create SSH Key…") { sheet = .createKey(account) }
                        }
                        Button("Sign Out") { store.signOut(account) }
                    }
                } label: {
                    Text(account.username)
                    Text("\(account.kind.title) · \(account.host)" + (account.sshKey != nil ? " · SSH key" : ""))
                }
            }
            HStack {
                Button("Sign In to GitHub…") { sheet = .browser(.github, host: nil) }
                Button("Sign In to GitLab…") { sheet = .browser(.gitlab, host: nil) }
                Spacer()
                Button("Add Token…") { sheet = .token }
            }
            Text("Used for HTTPS remotes on these servers, and for SSH remotes once you create an SSH key, only by git-cowork. Git in the terminal and other servers keep your own setup. Tokens and key passphrases are kept in the Keychain.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
        }
        .sheet(item: $sheet) { kind in
            switch kind {
            case .browser(let kind, let host): BrowserSignInSheet(kind: kind, host: host)
            case .token: TokenSheet()
            case .createKey(let account):
                CreateSSHKeySheet(account: account) { sheet = .browser(account.kind, host: account.host) }
            case .hostEntry(let account): SSHHostEntrySheet(account: account)
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

    init(kind: HostKind, host: String? = nil) {
        self.kind = kind
        _host = State(initialValue: host ?? defaultHost(kind))
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
        default: L("Add an application under User settings > Applications on that server (GitLab 17.3 or later): untick \"Confidential\", allow the device code grant, scopes read_user, api and write_repository. Paste its application ID. Or use Add Token instead.")
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
                Text("Needs the scopes \(HostAPI.tokenScopesHint(kind: kind)).")
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

/// Makes an SSH key for one account and adds it on the host.
struct CreateSSHKeySheet: View {
    let account: HostAccount
    /// Opens browser sign-in for this host, for tokens from before SSH keys.
    let signInAgain: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: SSHKeyError?
    @State private var task: Task<Void, Never>?

    private var shownPath: String {
        let path = SSHKeys.plannedPath(for: account) ?? SSHKeys.sshDir + "/git-cowork_\(SSHKey.sshHost(account.host))"
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        AccountSheetFrame(title: "Create SSH Key", error: error?.message) {
            Text("git-cowork makes a new key, adds it to \(account.username) on \(account.host), and uses it for SSH remotes on \(SSHKey.sshHost(account.host)).")
                .fixedSize(horizontal: false, vertical: true)
            Text("Saved as \(shownPath), with its passphrase in the Keychain. Your ~/.ssh/config isn't changed.")
                .font(Theme.Font.small).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if working {
                HStack(spacing: Theme.Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Creating key…").font(Theme.Font.small).foregroundStyle(.secondary)
                }
            }
        } buttons: {
            if error?.needsSignIn == true {
                if account.method == .oauth {
                    Button("Sign In Again…") { signInAgain() }
                } else if let page = HostAPI.newTokenPage(kind: account.kind, host: account.host) {
                    Link("Create a Token…", destination: page)
                }
            }
            Button("Cancel") { task?.cancel(); dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create Key") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
        }
    }

    private func create() {
        error = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                let path = try await SSHKeys.create(for: account)
                AccountStore.shared.setSSHKey(path, for: account)
                dismiss()
            } catch let e as SSHKeyError {
                error = e
            } catch {
                self.error = SSHKeyError(message: error.localizedDescription)
            }
        }
    }
}

/// The `Host` entry for ~/.ssh/config, for people who want ssh in the
/// terminal to use the key too. The app never writes that file itself.
struct SSHHostEntrySheet: View {
    let account: HostAccount
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var entry: String {
        account.sshKey.flatMap { SSHKey.hostEntry(host: account.host, keyPath: $0, home: NSHomeDirectory()) } ?? ""
    }

    var body: some View {
        AccountSheetFrame(title: "SSH Host Entry", error: nil) {
            Text("git-cowork already uses this key. To use it in the terminal too, add this near the top of ~/.ssh/config:")
                .fixedSize(horizontal: false, vertical: true)
            Text(entry)
                .font(Theme.Font.mono)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Metrics.cardPadding)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).stroke(Theme.cardBorder))
        } buttons: {
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry, forType: .string)
                copied = true
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
