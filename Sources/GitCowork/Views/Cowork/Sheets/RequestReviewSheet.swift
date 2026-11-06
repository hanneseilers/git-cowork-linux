import GitCoworkCore
import SwiftUI

/// Ask teammates to review a branch. Optionally opens the host's new
/// Pull/Merge Request page too. Afterwards shows the request in Reviews.
struct RequestReviewSheet: View {
    let model: RepoModel
    let branch: String

    @State private var base: String
    @State private var title: String
    @State private var note = ""
    @State private var reviewers: Set<String> = []
    @State private var taskID: String
    @State private var openPR = false
    @State private var pushing = false

    init(model: RepoModel, branch: String) {
        self.model = model
        self.branch = branch
        let defaultBase = model.baseBranch()?.name ?? "main"
        _base = State(initialValue: defaultBase == branch ? "" : defaultBase)
        let tip = model.branch(named: branch)?.target
        _title = State(initialValue: tip.flatMap { model.commit($0)?.subject } ?? branch)
        _taskID = State(initialValue: model.cowork.tasks.first { $0.branch == branch }?.id ?? "")
    }

    private var store: CoworkStore { model.cowork }
    private var links: RemoteLinks? { model.links(for: nil) }

    /// Local branches plus the remote's default, without the branch under review.
    private var baseOptions: [String] {
        var names = model.localBranches.map(\.name)
        if let d = model.baseBranch()?.name, !names.contains(d) { names.append(d) }
        if !base.isEmpty, !names.contains(base) { names.append(base) }
        return names.filter { $0 != branch }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var candidates: [TeamMember] { store.people.filter { $0.id != store.me.id } }

    private var openTasks: [CoworkTask] {
        store.tasks.filter { $0.status != .done || $0.id == taskID }
            .sorted { $0.updated > $1.updated }
    }

    /// Why reviewers can't see the branch yet, if they can't.
    private var pushProblem: String? {
        let local = model.localBranches.first { $0.name == branch }
        let onRemote = local?.upstream != nil
            || model.remoteBranches.contains { $0.branchNameWithoutRemote == branch }
        if !onRemote { return "\(branch) isn't on the remote yet. Push it so reviewers can fetch it." }
        if let local, local.ahead > 0 {
            return "\(local.ahead) commit\(local.ahead == 1 ? "" : "s") on \(branch) not pushed yet."
        }
        return nil
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !base.isEmpty && !reviewers.isEmpty
    }

    var body: some View {
        SheetScaffold(title: "Request Review", confirmTitle: "Request Review", confirmDisabled: !valid) {
            request()
        } content: {
            SheetGrid {
                SheetRow(label: "Branch") {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(branch).font(Theme.Font.mono).lineLimit(1).truncationMode(.middle)
                    }
                }
                SheetRow(label: "Into") {
                    Picker("Base", selection: $base) {
                        if base.isEmpty { Text("Choose…").tag("") }
                        ForEach(baseOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SheetRow(label: "Title") {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder).labelsHidden()
                }
                SheetRow(label: "Reviewers", top: true) { reviewerList }
                SheetRow(label: "Note", top: true) {
                    PlaceholderEditor(text: $note, placeholder: "What should reviewers look at? (optional)",
                                      minHeight: 60, maxHeight: 60)
                }
                SheetRow(label: "Task") {
                    Picker("Task", selection: $taskID) {
                        Text("None").tag("")
                        ForEach(openTasks) { t in
                            Text("\(t.id)  \(t.title)").tag(t.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let pushProblem {
                SheetNotice(symbol: "exclamationmark.triangle.fill", color: .orange, text: pushProblem) {
                    if pushing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Push Branch") { push() }
                            .buttonStyle(ActionButtonStyle.secondary(.orange))
                            .disabled(model.defaultRemote == nil || model.busy != nil)
                    }
                }
            }

            if let links {
                Toggle("Also open a \(links.pullRequestTerm) page on \(links.host)", isOn: $openPR)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var reviewerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if candidates.isEmpty {
                Text("No teammates known yet. Add them under Team, or they appear once they commit.")
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(candidates) { p in
                            Toggle(isOn: Binding(
                                get: { reviewers.contains(p.email) },
                                set: { if $0 { reviewers.insert(p.email) } else { reviewers.remove(p.email) } })) {
                                HStack(spacing: Theme.Space.s + 2) {
                                    PersonAvatar(person: p, size: 16)
                                    Text(p.displayName).lineLimit(1)
                                    Text(p.email).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(height: Theme.Metrics.rowHeight)
                        }
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(candidates.count), 5) * Theme.Metrics.rowHeight + Theme.Space.s)
                .editorBox()
            }
        }
    }

    private func push() {
        guard model.defaultRemote != nil else { return }
        pushing = true
        let b = branch
        Task {
            if model.currentBranch == b {
                await model.push()
            } else {
                await model.push(branch: b)
            }
            pushing = false
        }
    }

    private func request() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let body = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let rv = candidates.map(\.email).filter { reviewers.contains($0) }
        let b = branch, baseName = base, task = taskID.isEmpty ? nil : taskID
        let prURL = openPR ? links?.newPullRequestURL(branch: b, base: baseName) : nil
        Task {
            guard let r = await model.cowork.requestReview(branch: b, base: baseName, title: t, reviewers: rv,
                                                           body: body, taskID: task) else {
                model.alert = AlertItem(title: "Couldn't request the review",
                                        message: model.cowork.syncError ?? "Writing to refs/cowork/main failed.")
                return
            }
            model.openDiff = nil
            ReviewsView.showFilter(for: r, store: model.cowork)
            model.centerMode = .reviews
            model.coworkSelection = .review(r.id)
            if let prURL { External.browse(prURL) }
        }
    }
}
