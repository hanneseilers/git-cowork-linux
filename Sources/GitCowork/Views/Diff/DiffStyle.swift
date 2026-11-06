import AppKit

/// Metrics and colors of the diff view. Base tints come from `Theme.Diff`.
enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let metaFont = NSFont.systemFont(ofSize: 11)
    static let buttonFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static let lineHeight: CGFloat = 18
    static let hunkHeight: CGFloat = 30
    static let numberPadding: CGFloat = Theme.Space.m
    static let signWidth: CGFloat = 18
    static let textInset: CGFloat = Theme.Space.s
    /// Same inset as the diff header above, so the "@@" text lines up with the file name.
    static let hunkInset: CGFloat = Theme.Metrics.panelPadding
    static let topInset: CGFloat = Theme.Space.s

    // Hunk buttons are drawn to match ActionButtonStyle.secondary(tint).
    static let buttonHeight: CGFloat = Theme.Metrics.buttonHeight
    static let buttonPadding: CGFloat = Theme.Space.m + Theme.Space.xs
    static let buttonSpacing: CGFloat = Theme.Space.s + Theme.Space.xs
    static let buttonRadius: CGFloat = Theme.Radius.card

    /// Longer lines are cut when drawn (copying still gets the full line).
    static let maxDrawnColumns = 2_000

    static let addedBackground = Theme.Diff.addedBackground
    static let removedBackground = Theme.Diff.removedBackground
    static let addedGutter = NSColor.systemGreen.withAlphaComponent(0.22)
    static let removedGutter = NSColor.systemRed.withAlphaComponent(0.22)
    static let addedHighlight = NSColor.systemGreen.withAlphaComponent(0.34)
    static let removedHighlight = NSColor.systemRed.withAlphaComponent(0.34)
    static let addedSign = NSColor.systemGreen
    static let removedSign = NSColor.systemRed
    static let hunkBackground = Theme.Diff.hunkBackground
    static let gutterBackground = NSColor.labelColor.withAlphaComponent(0.035)
    static let emptySide = NSColor.labelColor.withAlphaComponent(0.06)
    static let separator = NSColor.separatorColor
    static let gutterText = Theme.Diff.gutterText
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let buttonBase = NSColor.textBackgroundColor
}
