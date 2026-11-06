import SwiftUI

/// Sizes and colors used only by the sidebar. Shared tokens come from Theme.
enum SidebarStyle {
    /// Every row, section headers included, is one standard list row tall.
    static let rowHeight: CGFloat = Theme.Metrics.rowHeight
    static let headerHeight: CGFloat = Theme.Metrics.rowHeight
    /// Horizontal step per tree level. Equals chevron column + spacing, so a
    /// child's chevron sits exactly under its parent's icon.
    static let indent: CGFloat = chevronWidth + Theme.Space.s
    /// Column for disclosure chevrons, reserved on every row so icons line up.
    static let chevronWidth: CGFloat = 10
    static let iconWidth: CGFloat = 16
    static let iconSize: CGFloat = 11
    static let chevronSize: CGFloat = 8
    static let currentDot: CGFloat = 6
    static let avatarSize: CGFloat = 16
    /// Width reserved for section counts so they right-align in one column.
    static let countWidth: CGFloat = 18
    /// Leading/trailing inset of row content. Together with the list's own cell
    /// padding this lines rows up with the filter field (Theme.Metrics.panelPadding).
    static let rowInsets = EdgeInsets(top: 0, leading: Theme.Space.s, bottom: 0, trailing: Theme.Space.s)

    static let rowFont = Theme.Font.body
    static let headerFont = Theme.Font.caption
    static let detailFont = Theme.Font.small

    /// Band behind the checked-out branch and the current worktree.
    static let currentBand = Color.accentColor.opacity(0.16)
    /// Padding the sidebar list adds inside each row on top of rowInsets.
    static let listCellPadding: CGFloat = 8
    /// The band covers the same area as the list's selection highlight.
    static let bandInset = EdgeInsets(top: 1, leading: -Theme.Space.s, bottom: 1, trailing: -Theme.Space.s)
    static let bandRadius: CGFloat = 5
}
