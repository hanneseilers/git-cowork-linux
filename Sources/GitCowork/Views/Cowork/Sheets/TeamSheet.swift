import GitCoworkCore
import SwiftUI

/// Edit team.md on the cowork ref: handle (for @mentions), name and email.
/// Starts from the saved team, or from everyone seen in commits.
struct TeamSheet: View {
    let model: RepoModel

    private struct Row: Identifiable, Hashable {
        let id = UUID()
        var handle: String
        var name: String
        var email: String
    }

    @State private var rows: [Row]

    init(model: RepoModel) {
        self.model = model
        let saved = model.cowork.snapshot.team
        let start = saved.isEmpty ? model.cowork.people : saved
        _rows = State(initialValue: start.map { Row(handle: $0.mentionHandle, name: $0.name, email: $0.email) })
    }

    private func emailOK(_ e: String) -> Bool {
        let parts = e.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty && !e.contains(" ")
    }

    private var problem: String? {
        let filled = rows.filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty }
        if let bad = filled.first(where: { !emailOK($0.email) }) { return String(localized: "“\(bad.email)” isn't an email address.") }
        let emails = filled.map { $0.email.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(emails).count != emails.count { return L("Each email can only be listed once.") }
        let handles = filled.map { handle(for: $0).lowercased() }
        if Set(handles).count != handles.count { return L("Handles must be unique.") }
        if filled.contains(where: { handle(for: $0).contains(where: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }) }) {
            return L("Handles may only use letters, digits, . _ and -.")
        }
        return nil
    }

    private func handle(for r: Row) -> String {
        let h = r.handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return h.isEmpty ? String(r.email.split(separator: "@").first ?? "") : h
    }

    var body: some View {
        SheetScaffold(title: "Team", confirmTitle: "Save Team", confirmDisabled: problem != nil) {
            save()
        } content: {
            Text("Saved in the repository for everyone. Handles are used for @mentions; emails match commits and git config user.email.")
                .font(Theme.Font.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.m) {
                    Text("Handle").frame(width: Layout.handle, alignment: .leading)
                    Text("Name").frame(width: Layout.name, alignment: .leading)
                    Text("Email").frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Layout.remove)
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.Metrics.rowHeight)
                Divider()
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        ForEach($rows) { $row in
                            HStack(spacing: Theme.Space.m) {
                                TextField("handle", text: $row.handle).frame(width: Layout.handle)
                                TextField("Name", text: $row.name).frame(width: Layout.name)
                                TextField("name@example.com", text: $row.email)
                                Button {
                                    rows.removeAll { $0.id == row.id }
                                } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .frame(width: Layout.remove)
                                .help("Remove")
                            }
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(Theme.Space.m)
                }
                .frame(height: 180)
            }
            .editorBox()

            HStack {
                Button {
                    rows.append(Row(handle: "", name: "", email: ""))
                } label: {
                    Label("Add Member", systemImage: "plus")
                }
                Spacer()
                if let problem {
                    Text(problem).font(Theme.Font.small).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }

    private enum Layout {
        static let handle: CGFloat = 80
        static let name: CGFloat = 120
        static let remove: CGFloat = 16
    }

    private func save() {
        let members = rows
            .filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { r in
                let email = r.email.trimmingCharacters(in: .whitespaces)
                let name = r.name.trimmingCharacters(in: .whitespaces)
                return TeamMember(handle: handle(for: r), name: name.isEmpty ? handle(for: r) : name, email: email)
            }
        Task { await model.cowork.saveTeam(members) }
    }
}
