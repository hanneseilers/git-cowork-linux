import GitCoworkCore
import AppKit
import SwiftUI

/// Design tokens. Every view takes spacing, sizes and colors from here so the
/// app stays consistent. Colors follow the system light/dark appearance.
enum Theme {
    enum Space {
        static let xs: CGFloat = 2
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    enum Radius {
        /// Chips, branch badges, status glyphs.
        static let badge: CGFloat = 4
        /// Buttons, segments, text fields and editors.
        static let control: CGFloat = 6
        /// Cards and banners.
        static let card: CGFloat = 8
    }

    /// Small SF Symbol glyphs that appear in many places.
    enum Glyph {
        /// Disclosure and "go to" chevrons (chevron.right).
        static let chevron = SwiftUI.Font.system(size: 9, weight: .semibold)
        /// Pop-up and menu chevrons (chevron.down).
        static let dropdown = SwiftUI.Font.system(size: 8, weight: .semibold)
    }

    /// Opacity of a color laid under tinted content, so every tint has the same strength.
    enum Tint {
        /// Chips, capsules, status glyphs, branch badges.
        static let chip: Double = 0.15
        /// Banners and notice boxes.
        static let banner: Double = 0.12
        /// Selected or current rows.
        static let selection: Double = 0.16
    }

    /// Quiet card surface (commit message, review summary, recent repos).
    static let cardFill = Color.primary.opacity(0.04)
    static let cardBorder = Color.primary.opacity(0.08)

    enum Font {
        static let body = SwiftUI.Font.system(size: 13)
        static let small = SwiftUI.Font.system(size: 11)
        /// Section titles ("Local", "Description", "Unstaged files") and their counts.
        static let caption = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
    }

    /// Layout rules shared by every panel, so edges line up across the window.
    enum Metrics {
        /// Height of every panel's top bar (sidebar filter row, center header,
        /// inspector header) so their bottom borders form one line.
        static let panelHeaderHeight: CGFloat = 40
        /// Left/right inset of content inside a panel.
        static let panelPadding: CGFloat = 12
        /// Vertical gap between groups inside a panel.
        static let sectionGap: CGFloat = 16
        /// Standard list row height (sidebar, file lists, review lists).
        static let rowHeight: CGFloat = 26
        /// Padding inside cards (task cards, message card, banners).
        static let cardPadding: CGFloat = 10
        /// Height of chips (status, labels, verdicts).
        static let chipHeight: CGFloat = 20
        /// Height of every small action button (`ActionButtonStyle`).
        static let buttonHeight: CGFloat = 22
        /// Borders: use Divider() / separatorColor at 1pt; never stack two.
        static let hairline: CGFloat = 1
    }

    /// Sidebar column (filter bar and list alike): a step lighter than the
    /// inspector in dark mode, a step darker in light mode.
    static let sidebarBackground = Color(nsColor: NSColor(name: "sidebarBackground") { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.20, alpha: 1)
            : NSColor(white: 0.93, alpha: 1)
    })

    /// Colors for task status, used on the board, chips and sidebar.
    static func status(_ s: TaskStatusColorKey) -> Color {
        switch s {
        case .backlog: Color(nsColor: .systemGray)
        case .todo: Color(nsColor: lanes[0])
        case .doing: Color(nsColor: lanes[3])
        case .review: Color(nsColor: lanes[4])
        case .done: Color(nsColor: lanes[2])
        }
    }

    enum TaskStatusColorKey { case backlog, todo, doing, review, done }

    /// Lane colors for the graph. Chosen to read well on light and dark backgrounds.
    static let lanes: [NSColor] = [
        NSColor(srgbRed: 0.27, green: 0.60, blue: 0.96, alpha: 1),  // blue
        NSColor(srgbRed: 0.90, green: 0.42, blue: 0.62, alpha: 1),  // pink
        NSColor(srgbRed: 0.36, green: 0.72, blue: 0.42, alpha: 1),  // green
        NSColor(srgbRed: 0.95, green: 0.62, blue: 0.22, alpha: 1),  // orange
        NSColor(srgbRed: 0.63, green: 0.47, blue: 0.86, alpha: 1),  // purple
        NSColor(srgbRed: 0.20, green: 0.72, blue: 0.76, alpha: 1),  // teal
        NSColor(srgbRed: 0.84, green: 0.71, blue: 0.20, alpha: 1),  // yellow
        NSColor(srgbRed: 0.92, green: 0.38, blue: 0.36, alpha: 1),  // red
        NSColor(srgbRed: 0.52, green: 0.58, blue: 0.94, alpha: 1),  // indigo
        NSColor(srgbRed: 0.68, green: 0.53, blue: 0.40, alpha: 1),  // brown
    ]

    static func lane(_ i: Int) -> NSColor { lanes[((i % lanes.count) + lanes.count) % lanes.count] }

    enum Status {
        static let added = Color(nsColor: .systemGreen)
        static let modified = Color(nsColor: .systemOrange)
        static let deleted = Color(nsColor: .systemRed)
        static let renamed = Color(nsColor: .systemBlue)
        static let conflicted = Color(nsColor: .systemPink)
        static let untracked = Color(nsColor: .systemTeal)
        /// Needs attention: conflicts banner, sync errors, uncommitted counts.
        static let warning = Color(nsColor: .systemOrange)
    }

    enum Diff {
        static let addedBackground = NSColor.systemGreen.withAlphaComponent(0.14)
        static let removedBackground = NSColor.systemRed.withAlphaComponent(0.14)
        static let hunkBackground = NSColor.systemBlue.withAlphaComponent(0.10)
        static let addedText = NSColor.labelColor
        static let gutterText = NSColor.tertiaryLabelColor
    }
}

extension Color {
    /// Tinted text on a soft fill of the same tint (chips, secondary buttons):
    /// the bright system colors are too light on white, so darken them a bit
    /// in light mode. Dark mode keeps the tint as is.
    func readableTint(_ scheme: ColorScheme) -> Color {
        guard scheme == .light else { return self }
        return Color(nsColor: NSColor(self).blended(withFraction: 0.28, of: .black) ?? NSColor(self))
    }
}

enum Formatters {
    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yy")
        return f
    }()

    /// "now", "5m", "3h", "2d", then a short date.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        return shortDate.string(from: date)
    }

    static func full(_ date: Date) -> String { dateTime.string(from: date) }
}


extension TaskStatus {
    var color: Color {
        switch self {
        case .backlog: Theme.status(.backlog)
        case .todo: Theme.status(.todo)
        case .doing: Theme.status(.doing)
        case .review: Theme.status(.review)
        case .done: Theme.status(.done)
        }
    }

    var symbol: String {
        switch self {
        case .backlog: "tray"
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .review: "eye"
        case .done: "checkmark.circle.fill"
        }
    }
}

extension ReviewVerdict {
    var color: Color {
        switch self {
        case .requested: Color(nsColor: .systemGray)
        case .approved: Color(nsColor: .systemGreen)
        case .changesRequested: Color(nsColor: .systemOrange)
        case .commented: Color(nsColor: .systemBlue)
        }
    }

    var title: String {
        switch self {
        case .requested: "Waiting"
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .commented: "Commented"
        }
    }

    var symbol: String {
        switch self {
        case .requested: "clock"
        case .approved: "checkmark.circle.fill"
        case .changesRequested: "exclamationmark.circle.fill"
        case .commented: "text.bubble"
        }
    }
}
