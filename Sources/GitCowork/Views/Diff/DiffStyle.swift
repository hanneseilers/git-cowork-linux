import AppKit

/// Metrics and colors of the diff view.
enum DiffStyle {
    static let font = Theme.AppKitFont.mono
    static let gutterFont = Theme.AppKitFont.monoSmall
    static let metaFont = Theme.AppKitFont.small
    static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static let lineHeight: CGFloat = 18
    static let hunkHeight: CGFloat = 30
    static let numberPadding: CGFloat = Theme.Space.m
    static let signWidth: CGFloat = 18
    static let textInset: CGFloat = Theme.Space.s
    /// Same inset as the diff header above, so the "@@" text lines up with the file name.
    static let hunkInset: CGFloat = Theme.Metrics.panelPadding

    // Hunk buttons are drawn to match ActionButtonStyle.secondary(tint).
    static let buttonHeight: CGFloat = Theme.Metrics.buttonHeight
    static let buttonPadding: CGFloat = Theme.Space.m + Theme.Space.xs
    static let buttonSpacing: CGFloat = Theme.Space.s + Theme.Space.xs
    static let buttonRadius: CGFloat = Theme.Radius.control

    /// Longer lines are cut when drawn (copying still gets the full line).
    static let maxDrawnColumns = 2_000

    static let addedBackground = NSColor.systemGreen.withAlphaComponent(0.14)
    static let removedBackground = NSColor.systemRed.withAlphaComponent(0.14)
    static let addedGutter = NSColor.systemGreen.withAlphaComponent(0.22)
    static let removedGutter = NSColor.systemRed.withAlphaComponent(0.22)
    static let addedHighlight = NSColor.systemGreen.withAlphaComponent(0.34)
    static let removedHighlight = NSColor.systemRed.withAlphaComponent(0.34)
    static let addedSign = NSColor.systemGreen
    static let removedSign = NSColor.systemRed
    static let hunkBackground = NSColor.systemBlue.withAlphaComponent(0.10)
    static let gutterBackground = NSColor.labelColor.withAlphaComponent(0.035)
    static let emptySide = NSColor.labelColor.withAlphaComponent(0.06)
    static let separator = NSColor.separatorColor
    static let gutterText = NSColor.tertiaryLabelColor
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let buttonBase = NSColor.textBackgroundColor
}
