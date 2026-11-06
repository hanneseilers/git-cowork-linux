import GitCoworkCore
import SwiftUI

// Small pieces shared by the board, review list, task/review panels and sidebar.

/// Initials avatar for a person, colored the same way everywhere (graph nodes
/// use lane colors; people use this stable per-email color).
struct PersonAvatar: View {
    let person: TeamMember?
    var size: CGFloat = 20

    var body: some View {
        if let person {
            Avatar(name: person.name.isEmpty ? person.email : person.name, email: person.email, size: size)
                .help("\(person.name) <\(person.email)>")
        } else {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.tertiary)
                .frame(width: size, height: size)
                .help("Unassigned")
        }
    }
}

/// Colored capsule with an icon: "In Progress", "Approved", label names.
struct Chip: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary
    var filled = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(Theme.Font.small.weight(.medium))
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Metrics.chipHeight)
        .foregroundStyle(filled ? Color.white : color.readableTint(scheme))
        .background(filled ? color : color.opacity(Theme.Tint.chip), in: Capsule())
    }
}

struct StatusChip: View {
    let status: TaskStatus
    var body: some View { Chip(text: status.title, symbol: status.symbol, color: status.color) }
}

struct VerdictChip: View {
    let verdict: ReviewVerdict
    var body: some View { Chip(text: verdict.title, symbol: verdict.symbol, color: verdict.color) }
}

/// Labels get a stable color from their name.
struct LabelChip: View {
    let label: String
    var body: some View {
        Chip(text: label, color: Color(nsColor: Theme.lane(label.lowercased().hashValueStable)))
    }
}

/// "CW-a3f9" in monospace, copyable.
struct TaskIDText: View {
    let id: String
    var body: some View {
        Text(id)
            .font(Theme.Font.monoSmall.weight(.medium))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
