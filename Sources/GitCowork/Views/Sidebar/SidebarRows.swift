import GitCoworkCore
import SwiftUI

// Rows of the sidebar list. Each is a single line of SidebarStyle.rowHeight.

/// Indentation, disclosure chevron slot and icon shared by every row.
struct SidebarRowLayout<Leading: View, Content: View>: View {
    var depth = 0
    var height = SidebarStyle.rowHeight
    @ViewBuilder var leading: Leading
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if depth > 0 { Color.clear.frame(width: CGFloat(depth) * SidebarStyle.indent) }
            ZStack { leading }.frame(width: SidebarStyle.chevronWidth, height: height)
            content
        }
        .font(SidebarStyle.rowFont)
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SidebarRowLayout where Leading == EmptyView {
    init(depth: Int = 0, height: CGFloat = SidebarStyle.rowHeight, @ViewBuilder content: () -> Content) {
        self.init(depth: depth, height: height, leading: { EmptyView() }, content: content)
    }
}

struct DisclosureChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: SidebarStyle.chevronSize, weight: .bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

struct SidebarIcon: View {
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: SidebarStyle.iconSize))
            .foregroundStyle(color)
            .frame(width: SidebarStyle.iconWidth)
    }
}

/// Badges at the end of a row. Laid out first and never truncated; names give way instead.
struct SidebarTrailing<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: Theme.Space.s) { content }
            .fixedSize()
            .layoutPriority(2)
    }
}

/// Tinted rounded band behind the checked-out branch / current worktree.
struct CurrentBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.background {
            if active {
                RoundedRectangle(cornerRadius: SidebarStyle.bandRadius)
                    .fill(SidebarStyle.currentBand)
                    .padding(SidebarStyle.bandInset)
            }
        }
    }
}

// MARK: - Header

/// "› [icon] LOCAL ……… [+] 12". Clicking anywhere toggles the section.
struct SidebarSectionHeader<Trailing: View>: View {
    let section: SidebarSection
    let count: Int
    /// Nil when the header can't collapse (filtered results).
    let expanded: Bool?
    /// Accent count (reviews waiting for me).
    var highlight = false
    var showsDivider = true
    var toggle: () -> Void = {}
    @ViewBuilder var trailing: Trailing

    var body: some View {
        SidebarRowLayout(height: SidebarStyle.headerHeight) {
            if let expanded { DisclosureChevron(expanded: expanded) }
        } content: {
            SidebarIcon(symbol: section.symbol)
            Text(section.title.uppercased())
                .font(SidebarStyle.headerFont)
                .foregroundStyle(.secondary)
                .kerning(0.3)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                trailing
                SidebarCount(count: count, highlight: highlight)
            }
        }
        .overlay(alignment: .top) {
            if showsDivider { Divider().padding(.horizontal, SidebarStyle.bandInset.leading) }
        }
        .onTapGesture { toggle() }
    }
}

extension SidebarSectionHeader where Trailing == EmptyView {
    init(section: SidebarSection, count: Int, expanded: Bool?, highlight: Bool = false,
         showsDivider: Bool = true, toggle: @escaping () -> Void = {}) {
        self.init(section: section, count: count, expanded: expanded, highlight: highlight,
                  showsDivider: showsDivider, toggle: toggle) { EmptyView() }
    }
}

/// Section count, right-aligned in a fixed column so counts line up across headers.
/// Highlighted counts get an accent capsule.
struct SidebarCount: View {
    let count: Int
    var highlight = false

    var body: some View {
        Text(verbatim: "\(count)")
            .font(Theme.Font.caption.monospacedDigit())
            .foregroundStyle(highlight ? Color.white : Color.secondary)
            .padding(.horizontal, highlight ? 5 : 0)
            .frame(minWidth: SidebarStyle.countWidth, minHeight: 15, alignment: highlight ? .center : .trailing)
            .background {
                if highlight { Capsule().fill(Color.accentColor) }
            }
    }
}

/// Small borderless "+" button for section headers.
struct SidebarHeaderButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: SidebarStyle.iconSize, weight: .medium))
                .frame(width: SidebarStyle.iconWidth, height: SidebarStyle.iconWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Tree rows

/// Branch folder ("claude", "feature") or remote ("origin"). Click toggles.
struct SidebarGroupRow: View {
    let name: String
    let symbol: String
    let expanded: Bool
    let depth: Int
    let toggle: () -> Void

    var body: some View {
        SidebarRowLayout(depth: depth) {
            DisclosureChevron(expanded: expanded)
        } content: {
            SidebarIcon(symbol: symbol)
            Text(name).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .onTapGesture { toggle() }
    }
}

/// Local or remote branch, or tag.
struct SidebarRefRow: View {
    let ref: Ref
    let label: String
    let depth: Int

    var body: some View {
        SidebarRowLayout(depth: depth) {
            SidebarIcon(symbol: symbol, color: ref.isHead ? .accentColor : .secondary)
            Text(label)
                .fontWeight(ref.isHead ? .semibold : .regular)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if ref.upstreamGone {
                    Image(systemName: "cloud.slash")
                        .font(.system(size: SidebarStyle.iconSize))
                        .foregroundStyle(.tertiary)
                        .help("Upstream branch was deleted")
                }
                if ref.ahead > 0 || ref.behind > 0 { AheadBehind(ahead: ref.ahead, behind: ref.behind) }
            }
        }
        .modifier(CurrentBand(active: ref.isHead))
        .help(ref.upstream.map { "\(ref.name) → \($0)" } ?? ref.name)
    }

    private var symbol: String {
        switch ref.kind {
        case .localBranch: ref.isHead ? "checkmark" : "arrow.triangle.branch"
        case .remoteBranch: "arrow.triangle.branch"
        case .tag: "tag"
        }
    }
}

/// Worktree: [branch] name  [folder] dir   3  ↑1. The current one gets a band and a dot.
/// The folder is shown only when both names fit; otherwise the branch gets the
/// whole width and the folder moves to the tooltip.
struct SidebarWorktreeRow: View {
    let model: RepoModel
    let wt: Worktree
    let isCurrent: Bool
    /// Repository name, used to shorten folder names like "repo-feature-x".
    let repoName: String

    var body: some View {
        let folder = wt.sidebarFolderLabel(repoName: repoName)
        SidebarRowLayout {
            if isCurrent {
                Circle().fill(Color.accentColor).frame(width: SidebarStyle.currentDot, height: SidebarStyle.currentDot)
            }
        } content: {
            SidebarIcon(symbol: wt.branch == nil ? "smallcircle.filled.circle" : "arrow.triangle.branch",
                        color: isCurrent ? .accentColor : .secondary)
            if let folder {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Space.m) {
                        branchText.fixedSize()
                        folderText(folder).fixedSize()
                    }
                    branchText.truncationMode(.middle)
                }
            } else {
                branchText.truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if wt.isPrunable {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.tertiary)
                        .help("Folder is missing; prune to clean up")
                }
                if wt.isLocked {
                    Image(systemName: "lock").foregroundStyle(.tertiary).help("Locked")
                }
                // Own view, so `git status` results arriving per worktree only
                // redraw this badge, not the whole sidebar list.
                WorktreeInfoBadges(model: model, path: wt.path)
            }
        }
        .modifier(CurrentBand(active: isCurrent))
        .help(folder.map { "\(branchLabel)\n\($0) — \(wt.path)" } ?? "\(branchLabel)\n\(wt.path)")
    }

    private var branchText: some View {
        Text(branchLabel).fontWeight(isCurrent ? .semibold : .regular)
    }

    private func folderText(_ folder: String) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "folder").font(.system(size: SidebarStyle.iconSize - 1))
            Text(folder)
        }
        .font(SidebarStyle.detailFont)
        .foregroundStyle(.secondary)
    }

    private var branchLabel: String {
        if let b = wt.branch { return b }
        return wt.head.map { "detached " + String($0.prefix(7)) } ?? "detached"
    }
}

/// Change count and ahead/behind for one worktree, read straight from the model.
struct WorktreeInfoBadges: View {
    let model: RepoModel
    let path: String

    var body: some View {
        if let info = model.worktreeInfo[path] {
            if info.changes > 0 { ChangeCountPill(count: info.changes) }
            if info.ahead > 0 || info.behind > 0 { AheadBehind(ahead: info.ahead, behind: info.behind) }
        }
    }
}

/// Uncommitted change count in a small orange capsule.
struct ChangeCountPill: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(Theme.Font.caption.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.Status.modified.opacity(0.2), in: Capsule())
            .foregroundStyle(Theme.Status.modified)
            .help("\(count) uncommitted changes")
    }
}

struct SidebarStashRow: View {
    let stash: Stash

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: "tray")
            Text(stash.message).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help("\(stash.selector): \(stash.message)")
    }
}

// MARK: - Cowork rows

/// One of my tasks: [status icon] CW-a3f9 Title.
struct SidebarTaskRow: View {
    let task: CoworkTask

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: task.status.symbol, color: task.status.color)
            Text(task.id)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(task.title).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help("\(task.id) · \(task.status.title)\n\(task.title)")
    }
}

/// Review request: [overall verdict icon] branch ……… requester / approvals.
struct SidebarReviewRow: View {
    let review: ReviewRequest
    /// I'm asked and haven't answered.
    let waiting: Bool
    let requester: TeamMember?

    var body: some View {
        let overall = review.overall
        SidebarRowLayout {
            SidebarIcon(symbol: overall.symbol, color: waiting ? .accentColor : overall.color)
            Text(review.branch)
                .fontWeight(waiting ? .semibold : .regular)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            SidebarTrailing {
                if waiting {
                    PersonAvatar(person: requester, size: SidebarStyle.avatarSize)
                } else {
                    Text(verbatim: "\(approvals)/\(review.reviewers.count)")
                        .font(Theme.Font.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(approvals) of \(review.reviewers.count) approved")
                }
            }
        }
        .help(waiting
              ? "\(requester?.name ?? review.requester) asked you to review \(review.branch)\n\(review.title)"
              : "\(review.branch): \(overall.title)\n\(review.title)")
    }

    private var approvals: Int { review.reviewers.values.filter { $0 == .approved }.count }
}

/// Team member: [avatar] Name @handle.
struct SidebarPersonRow: View {
    let person: TeamMember
    let isMe: Bool

    var body: some View {
        SidebarRowLayout {
            Avatar(name: person.name.isEmpty ? person.email : person.name, email: person.email,
                   size: SidebarStyle.avatarSize)
                .frame(width: SidebarStyle.iconWidth)
            Text(person.name.isEmpty ? person.email : person.name)
            if !person.handle.isEmpty {
                Text(verbatim: "@" + person.handle)
                    .font(SidebarStyle.detailFont)
                    .foregroundStyle(.secondary)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.s)
            if isMe {
                Text("you")
                    .font(SidebarStyle.detailFont)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .help("\(person.name) <\(person.email)>")
    }
}

/// "All Tasks…", "Edit Team…": a quiet clickable row at the end of a section.
struct SidebarLinkRow: View {
    let link: SidebarLink
    let action: () -> Void

    var body: some View {
        SidebarRowLayout {
            SidebarIcon(symbol: link.symbol, color: Color(nsColor: .tertiaryLabelColor))
            Text(link.title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .onTapGesture(perform: action)
    }
}

/// Muted placeholder line inside an empty section.
struct SidebarNoteRow: View {
    let text: String

    var body: some View {
        SidebarRowLayout {
            Color.clear.frame(width: SidebarStyle.iconWidth)
            Text(text)
                .font(SidebarStyle.detailFont)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Filter

/// Rounded filter field with a count ("106" / "3 matches") and a clear button.
struct SidebarFilterField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let count: Int

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter (⌥⌘F)", text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onExitCommand { text = "" }
            Text(text.isEmpty ? "Viewing \(count)" : "\(count) \(count == 1 ? "match" : "matches")")
                .font(SidebarStyle.detailFont.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear filter")
            }
        }
        .font(Theme.Font.body)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 26)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.6) : .clear)
        }
    }
}
