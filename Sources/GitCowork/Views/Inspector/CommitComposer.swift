import GitCoworkCore
import SwiftUI

/// Commit box at the bottom of the changes panel: summary with a character
/// hint, description, amend, and one wide commit button.
struct CommitComposer: View {
    @Bindable var model: RepoModel
    @FocusState private var focus: Field?

    private enum Field { case summary, details }

    private var session: InspectorSession { InspectorSession.of(model) }
    private var amend: Bool { session.amend && canAmend }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Commit").font(Theme.Font.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Amend previous commit", isOn: $session.amend)
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.small)
                    .disabled(!canAmend)
                    .help(canAmend ? "Rewrite the last commit with the staged changes"
                                   : "Nothing to amend while a merge or another operation is in progress")
                    .onChange(of: session.amend) { _, on in amendChanged(on) }
                    .onChange(of: canAmend) { _, ok in if !ok && session.amend { session.amend = false } }
            }

            HStack(spacing: Theme.Space.s) {
                TextField("Summary", text: $model.draftSummary)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .summary)
                    .onSubmit { focus = .details }
                Text("\(remaining)")
                    .font(Theme.Font.small.monospacedDigit())
                    .foregroundStyle(remaining < 0 ? Theme.Status.warning : Color.secondary)
                    .help("Characters left before \(InspectorStyle.summaryLimit)")
            }
            .font(Theme.Font.body)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 6)
            .modifier(EditorBox(focused: focus == .summary))

            TextEditor(text: $model.draftDetails)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .details)
                .frame(height: InspectorStyle.descriptionHeight)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
                .overlay(alignment: .topLeading) {
                    if model.draftDetails.isEmpty {
                        Text("Description")
                            .font(Theme.Font.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, Theme.Space.s)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(EditorBox(focused: focus == .details))

            Button(action: commit) {
                Text(buttonTitle)
                    .font(Theme.Font.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(InspectorStyle.commitTint)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit)
            .help("Commit (⌘↩)")
        }
        .padding(InspectorStyle.padding)
        .onAppear {
            if session.amend && !canAmend { session.resetAmend() }
            takeFocusRequest()
        }
        .onChange(of: model.focusSummaryToken) { _, _ in takeFocusRequest() }
    }

    private var remaining: Int { InspectorStyle.summaryLimit - model.draftSummary.count }

    private var message: String {
        let s = model.draftSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = model.draftDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? s : s + "\n\n" + d
    }

    private var hasSummary: Bool { !model.draftSummary.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Amending makes no sense during a merge/rebase or before the first commit.
    private var canAmend: Bool { model.operation == nil && model.headSHA != nil }

    private var canCommit: Bool {
        if model.busy != nil { return false }
        if model.operation == .merge { return model.status.conflicted.isEmpty }
        if amend { return true }
        return !model.status.staged.isEmpty && hasSummary
    }

    private var buttonTitle: String {
        let n = model.status.staged.count
        let files = "\(n) file\(n == 1 ? "" : "s")"
        if model.operation == .merge { return "Commit Merge" }
        if amend { return n == 0 ? "Amend Previous Commit" : "Amend Previous Commit with \(files)" }
        if n == 0 { return "Stage Changes to Commit" }
        return "Commit Changes to \(files)"
    }

    private func commit() {
        let msg = message
        let isAmend = amend
        Task {
            if await model.commit(message: msg, amend: isAmend) {
                model.draftSummary = ""
                model.draftDetails = ""
                session.resetAmend()
            }
        }
    }

    /// Ticking amend borrows HEAD's message (if the draft is empty); unticking
    /// gives back what the user had, unless they edited the borrowed message.
    private func amendChanged(_ on: Bool) {
        let s = session
        if on {
            s.preAmendDraft = (model.draftSummary, model.draftDetails)
            if model.draftSummary.isEmpty { Task { await loadLastMessage() } }
        } else {
            if let loaded = s.loadedAmendMessage,
               model.draftSummary == loaded.summary, model.draftDetails == loaded.details {
                model.draftSummary = s.preAmendDraft?.summary ?? ""
                model.draftDetails = s.preAmendDraft?.details ?? ""
            }
            s.preAmendDraft = nil
            s.loadedAmendMessage = nil
        }
    }

    private func loadLastMessage() async {
        guard let sha = model.headSHA, let d = await model.commitDetail(sha) else { return }
        // A late answer must not overwrite typing, or apply after unticking.
        guard session.amend, model.draftSummary.isEmpty else { return }
        model.draftSummary = d.subject
        model.draftDetails = d.body
        session.loadedAmendMessage = (d.subject, d.body)
    }

    /// Focuses the summary when model.focusSummaryToken moved since we last looked.
    /// Remembered per model because the panel is rebuilt when the selection changes.
    private func takeFocusRequest() {
        let token = model.focusSummaryToken
        guard token != session.focusHandled else { return }
        session.focusHandled = token
        DispatchQueue.main.async { focus = .summary }
    }
}
