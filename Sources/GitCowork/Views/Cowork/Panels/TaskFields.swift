import GitCoworkCore
import SwiftUI

// Pickers and editors for task fields, used by the task panel and the New Task sheet.

/// Status chip that opens a menu of all statuses.
struct StatusMenu: View {
    let status: TaskStatus
    let onChange: (TaskStatus) -> Void

    var body: some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { s in
                Button { onChange(s) } label: { s.menuLabel }
                    .disabled(s == status)
            }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                StatusChip(status: status)
                Image(systemName: "chevron.down")
                    .font(Theme.Glyph.dropdown)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change status")
    }
}

/// Avatar + name that opens a menu: Unassigned, Me, then everyone else.
struct AssigneeMenu: View {
    let store: CoworkStore
    let assignee: String?
    let onChange: (String?) -> Void

    var body: some View {
        Menu {
            AssigneeOptions(store: store) { email, title, icon in
                Button { onChange(email) } label: { Label { Text(title) } icon: { icon } }
                    .disabled(assignee?.lowercased() == email?.lowercased())
            }
        } label: {
            HStack(spacing: Theme.Space.s + 2) {
                PersonAvatar(person: store.person(assignee), size: 18)
                Text(displayName(assignee, in: store))
                    .font(Theme.Font.body)
                    .foregroundStyle(assignee == nil ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Theme.Glyph.dropdown)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Assign")
    }
}

/// Label chip with a remove button.
struct RemovableLabelChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        let color = Color(nsColor: Theme.labelColor(label))
        HStack(spacing: Theme.Space.s) {
            Text(label).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .semibold))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove label")
        }
        .font(Theme.Font.small.weight(.medium))
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.s)
        .frame(height: Theme.Metrics.chipHeight)
        .foregroundStyle(color)
        .background(color.opacity(Theme.Tint.chip), in: Capsule())
    }
}

/// Labels as chips with ×, plus a field to add one. Suggests labels used on other tasks.
struct LabelEditor: View {
    let labels: [String]
    /// Every label used anywhere, for suggestions.
    let known: [String]
    /// New labels to append (already deduplicated against `labels`). Sent as
    /// add/remove rather than a whole list, so quick edits can't undo each other.
    let onAdd: ([String]) -> Void
    let onRemove: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces).lowercased()
        let taken = Set(labels.map { $0.lowercased() })
        let free = known.filter { !taken.contains($0.lowercased()) }
        let hits = q.isEmpty ? free : free.filter { $0.lowercased().hasPrefix(q) && $0.lowercased() != q }
        return Array(hits.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s + 2) {
            FlowRow {
                ForEach(labels, id: \.self) { l in
                    RemovableLabelChip(label: l) { onRemove(l) }
                }
                TextField("Add label", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.small)
                    .frame(width: 84, height: Theme.Metrics.chipHeight)
                    .padding(.horizontal, Theme.Space.m)
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: focused ? [] : [3, 2])))
                    .focused($focused)
                    .onSubmit { add(draft) }
            }
            if focused, !suggestions.isEmpty {
                FlowRow {
                    ForEach(suggestions, id: \.self) { s in
                        Button { add(s) } label: {
                            HStack(spacing: Theme.Space.xs) {
                                Image(systemName: "plus").font(.system(size: 7, weight: .semibold))
                                Text(s)
                            }
                            .font(Theme.Font.small)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Space.m)
                            .frame(height: Theme.Metrics.chipHeight)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        draft = ""
        guard !names.isEmpty else { return }
        var added: [String] = []
        for n in names where !(labels + added).contains(where: { $0.lowercased() == n.lowercased() }) {
            // Reuse the existing spelling of a known label.
            added.append(known.first { $0.lowercased() == n.lowercased() } ?? n)
        }
        if !added.isEmpty { onAdd(added) }
    }
}
