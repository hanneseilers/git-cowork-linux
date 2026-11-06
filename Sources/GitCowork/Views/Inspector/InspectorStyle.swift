import SwiftUI

/// Sizes and fonts used only by the right-hand panel.
enum InspectorStyle {
    static let linkLabelWidth: CGFloat = 48
    /// Secondary bars inside a panel ("2 modified  Path | Tree").
    static let subheaderHeight: CGFloat = 34
    static let subjectFont = SwiftUI.Font.system(size: 17, weight: .semibold)
    static let avatarSize: CGFloat = 40
    static let coAuthorAvatarSize: CGFloat = 18
    static let messageMaxHeight: CGFloat = 220
    static let indent: CGFloat = 14
    static let summaryLimit = 72
    static let descriptionHeight: CGFloat = 72
    static let bannerTint = Color.accentColor
    static let commitTint = Color(nsColor: .systemGreen)
}
