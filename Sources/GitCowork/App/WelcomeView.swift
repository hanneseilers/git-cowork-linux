import AppKit
import SwiftUI

/// Shown in an empty tab: open, clone, or pick a recent repository.
struct WelcomeView: View {
    let open: (String) -> Void
    let clone: () -> Void
    @State private var recents = Prefs.recentRepos.filter { FileManager.default.fileExists(atPath: $0) }

    private enum Layout {
        static let contentWidth: CGFloat = 640
        static let topPadding: CGFloat = 72
        static let titleSize: CGFloat = 26
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("git-cowork").font(.system(size: Layout.titleSize, weight: .semibold))
                    Text("Branches, history and worktrees. Plain git underneath.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: Theme.Space.l) {
                    WelcomeTile(title: "Open Repository…", subtitle: "A repository or worktree folder",
                                symbol: "folder", shortcut: "⌘O", action: chooseFolder)
                    WelcomeTile(title: "Clone Repository…", subtitle: "From a URL into a new folder",
                                symbol: "arrow.down.circle", shortcut: "⇧⌘O", action: clone)
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.m) {
                        Text("Recent").font(Theme.Font.caption).foregroundStyle(.secondary)
                        CountBadge(count: recents.count)
                    }
                    .padding(.horizontal, Theme.Space.m)
                    if recents.isEmpty {
                        Text("Repositories you open show up here.")
                            .font(Theme.Font.small)
                            .foregroundStyle(.tertiary)
                            .padding(Theme.Space.m)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recents, id: \.self) { path in
                                RecentRow(path: path) { open(path) }
                                    .contextMenu {
                                        Button("Open") { open(path) }
                                        Button("Reveal in Finder") { External.reveal(path) }
                                        Divider()
                                        Button("Remove from Recents") { remove(path) }
                                    }
                            }
                        }
                    }
                }

                Text("Tip: drop a folder anywhere in this window.")
                    .font(Theme.Font.small)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, Theme.Space.m)
            }
            .frame(maxWidth: Layout.contentWidth, alignment: .leading)
            .padding(.top, Layout.topPadding)
            .padding([.horizontal, .bottom], Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        // Dropping a folder is handled by RepoWindow for every window.
        .navigationTitle("New Tab")
    }

    private func chooseFolder() {
        if let path = RepoPicker.choose() { open(path) }
    }

    private func remove(_ path: String) {
        recents.removeAll { $0 == path }
        Prefs.recentRepos = Prefs.recentRepos.filter { $0 != path }
    }
}

/// Large action card: icon, title, one line of help, shortcut.
private struct WelcomeTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Image(systemName: symbol)
                    .font(ChromeStyle.tileIcon)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).font(Theme.Font.body.weight(.medium))
                    Text(subtitle).font(Theme.Font.small).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(shortcut).font(Theme.Font.small).foregroundStyle(.tertiary)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Theme.cardFill))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Theme.cardBorder))
        }
        .buttonStyle(ChromeButtonStyle(horizontalPadding: 0))
    }
}

/// Recent repository: folder name, abbreviated path; highlights on hover.
private struct RecentRow: View {
    let path: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text((path as NSString).lastPathComponent)
                    .font(Theme.Font.body.weight(.medium))
                    .lineLimit(1)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ChromeButtonStyle())
        .help(path)
    }
}

enum RepoPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git repository or worktree folder"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
