import GitCoworkCore
import SwiftUI

/// New task: title, description, status, assignee, labels. Creates one commit
/// on the cowork ref, then shows the task on the board.
struct NewTaskSheet: View {
    let model: RepoModel
    let status: TaskStatus

    @State private var title = ""
    @State private var details = ""
    @State private var pickedStatus: TaskStatus
    @State private var assignee = ""          // "" = unassigned
    @State private var labels: [String] = []

    init(model: RepoModel, status: TaskStatus) {
        self.model = model
        self.status = status
        _pickedStatus = State(initialValue: status)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetScaffold(title: "New Task", confirmTitle: "Create Task", confirmDisabled: trimmedTitle.isEmpty) {
            create()
        } content: {
            TextField("Title", text: $title, prompt: Text("What needs doing?"))
                .textFieldStyle(.roundedBorder)
            PlaceholderEditor(text: $details, placeholder: "Description (optional)",
                              minHeight: 90, maxHeight: 90)
            if let q = MentionCompletion.pendingQuery(in: details) {
                let people = MentionCompletion.candidates(q, people: model.cowork.people)
                if !people.isEmpty {
                    MentionSuggestions(people: people) { details = MentionCompletion.complete(details, with: $0) }
                }
            }
            SheetGrid {
                SheetRow(label: "Status") {
                    Picker("Status", selection: $pickedStatus) {
                        ForEach(TaskStatus.allCases, id: \.self) { s in
                            Label { Text(s.title) } icon: { menuSymbol(s.symbol, s.color) }.tag(s)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SheetRow(label: "Assignee") {
                    Picker("Assignee", selection: $assignee) {
                        Text("Unassigned").tag("")
                        if !model.cowork.me.email.isEmpty {
                            Text("Me (\(model.cowork.me.displayName))").tag(model.cowork.me.email)
                        }
                        Divider()
                        ForEach(model.cowork.people.filter { $0.id != model.cowork.me.id }) { p in
                            Text(p.displayName).tag(p.email)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SheetRow(label: "Labels") {
                    LabelEditor(labels: labels, known: model.cowork.allLabels,
                                onAdd: { labels += $0 }, onRemove: { l in labels.removeAll { $0 == l } })
                }
            }
        }
    }

    private func create() {
        let t = trimmedTitle, body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = pickedStatus, a = assignee.isEmpty ? nil : assignee, l = labels
        Task {
            guard let task = await model.cowork.createTask(title: t, status: s, assignee: a, labels: l, body: body) else {
                model.alert = AlertItem(title: "Couldn't create the task", message: model.cowork.syncError ?? "Writing to refs/cowork/main failed.")
                return
            }
            model.openDiff = nil
            model.centerMode = .board
            model.coworkSelection = .task(task.id)
        }
    }
}
