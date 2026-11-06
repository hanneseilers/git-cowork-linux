import AppKit
import GitCoworkCore
import SwiftUI

/// One task card. Takes only plain values (looked up once per board render),
/// so SwiftUI can skip cards whose data didn't change.
struct BoardCard: View, Equatable {
    let task: CoworkTask
    let assignee: TeamMember?
    /// Overall verdict of an open review for the task's branch.
    let verdict: ReviewVerdict?
    let comments: Int
    let selected: Bool

    @State private var hovered = false

    static func == (a: BoardCard, b: BoardCard) -> Bool {
        a.task == b.task && a.assignee == b.assignee && a.verdict == b.verdict
            && a.comments == b.comments && a.selected == b.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(task.title)
                .font(Theme.Font.body.weight(.medium))
                .foregroundStyle(task.status == .done ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if !task.labels.isEmpty { labels }
            if let branch = task.branch, !branch.isEmpty { branchRow(branch) }

            HStack(spacing: Theme.Space.m) {
                // Same look as TaskIDText, without text selection: selectable
                // text would swallow the clicks and drags that move the card.
                Text(task.id)
                    .font(Theme.Font.monoSmall.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if comments > 0 {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 10))
                        Text(verbatim: "\(comments)")
                            .font(Theme.Font.small.monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .help("\(comments) comment\(comments == 1 ? "" : "s")")
                }
                PersonAvatar(person: assignee, size: 18)
            }
            .frame(height: 18)
        }
        .padding(Theme.Metrics.cardPadding)
        .background(background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: selected ? 2 : Theme.Metrics.hairline))
        .contentShape(shape)
        .onHover { hovered = $0 }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.card) }

    private var background: some View {
        Color(nsColor: .controlBackgroundColor)
            .overlay(Color.primary.opacity(hovered && !selected ? 0.035 : 0))
    }

    private var borderColor: Color {
        if selected { return .accentColor }
        return Color(nsColor: .separatorColor).opacity(hovered ? 1 : 0.7)
    }

    /// Up to three labels, then "+2". Wraps in narrow columns.
    private var labels: some View {
        FlowRow {
            ForEach(task.labels.prefix(3), id: \.self) { LabelChip(label: $0) }
            if task.labels.count > 3 {
                Text(verbatim: "+\(task.labels.count - 3)")
                    .font(Theme.Font.small)
                    .foregroundStyle(.secondary)
                    .help(task.labels.dropFirst(3).joined(separator: ", "))
                    .frame(height: Theme.Metrics.chipHeight)
            }
        }
    }

    private func branchRow(_ branch: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(branch)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let verdict {
                Image(systemName: verdict.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(verdict.color)
                    .help("Review: \(verdict.title)")
            }
        }
        .help(branch)
    }
}
