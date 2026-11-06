import AppKit

/// Sizes, fonts and alphas for the history table and its graph.
/// Lane colors come from Theme.lane so the sidebar and graph match.
enum GraphStyle {
    static let rowHeight: CGFloat = 34

    // Graph geometry
    static let laneWidth: CGFloat = 24
    static let graphInset: CGFloat = 6           // left padding inside the graph column
    static let nodeDiameter: CGFloat = 20
    static let mergeDotDiameter: CGFloat = 9
    static let lineWidth: CGFloat = 2.5
    static let bendRadius: CGFloat = 10
    static let headRingGap: CGFloat = 2.5        // space between node and HEAD ring
    static let headRingWidth: CGFloat = 2
    static let wipDash: [CGFloat] = [3, 2.5]
    static let maxGraphWidth: CGFloat = 360        // about 14 lanes; wider graphs clip with a fade
    static let nodeRingWidth: CGFloat = 2          // lane-colored ring around the author-colored node
    static let clipFadeWidth: CGFloat = 14
    static let minGraphWidth: CGFloat = 60

    /// Center x of a lane inside the graph column.
    static func x(_ lane: Int) -> CGFloat {
        graphInset + CGFloat(lane) * laneWidth + laneWidth / 2
    }

    /// Center x of a node in a graph column `width` wide. Lanes past the
    /// right edge are pinned to the last visible slot so the node never disappears.
    static func nodeX(_ lane: Int, width: CGFloat) -> CGFloat {
        max(x(0), min(x(lane), width - laneWidth / 2))
    }

    /// Fill color for an author's node: the same color the Avatar view uses.
    static func authorColor(email: String) -> NSColor {
        Theme.lane(abs(email.lowercased().hashValueStable))
    }

    /// Opaque color of the selected band as it looks over the table background.
    static func selectedBandColor(_ lane: NSColor, emphasized: Bool) -> NSColor {
        let alpha = Band.selectedAlpha * (emphasized ? 1 : Band.unemphasizedFactor)
        return NSColor.controlBackgroundColor.blended(withFraction: alpha, of: lane) ?? lane
    }

    // Row bands
    enum Band {
        static let verticalInset: CGFloat = 2
        static let alpha: CGFloat = 0.12
        static let selectedAlpha: CGFloat = 0.70
        static let unemphasizedFactor: CGFloat = 0.85  // window not key / table not focused
        static let selectedWashAlpha: CGFloat = 0.10   // left of the node on the selected row
        static let hoverAlpha: CGFloat = 0.05
        static let dimFactor: CGFloat = 0.4            // band alpha multiplier for dimmed rows
    }

    /// Text and node alpha for commits not on the current branch.
    static let dimmedAlpha: CGFloat = 0.45

    enum Text {
        static let padding: CGFloat = 8
        /// Leading inset of the first column (header title and badge), same as other panels.
        static let leadingPadding: CGFloat = Theme.Metrics.panelPadding
        static let subject = NSFont.systemFont(ofSize: 13)
        static let body = NSFont.systemFont(ofSize: 12)
        static let small = NSFont.systemFont(ofSize: 12)
        static let sha = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let initials = NSFont.systemFont(ofSize: 9, weight: .semibold)
        static let header = NSFont.systemFont(ofSize: 11, weight: .semibold)  // = Theme.Font.caption
        /// The "// WIP" marker.
        static let wip = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        static let bodySeparator = "   "
    }

    enum Badge {
        static let height: CGFloat = 20
        static let hPadding: CGFloat = 6
        static let iconSize: CGFloat = 9.5
        static let iconSpacing: CGFloat = 4
        static let gap: CGFloat = 4
        static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        static let moreFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        static let remoteOnlyAlpha: CGFloat = 0.5
        static let fillDarken: CGFloat = 0.2           // local badges: lane color, slightly darker for text contrast
        static let connectorWidth: CGFloat = 1.5
    }

    enum WIP {
        static let boxHeight: CGFloat = 22
        static let boxMinWidth: CGFloat = 180
        static let boxMaxFraction: CGFloat = 0.5       // of the message column
        static let countSpacing: CGFloat = 10
    }

    enum Cowork {
        static let chipHeight: CGFloat = 18
        static let chipPadding: CGFloat = 4
        static let chipFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        static let chipFillAlpha = CGFloat(Theme.Tint.chip)
        static let iconSize: CGFloat = 11
        static let gap: CGFloat = 6
    }

    enum Header {
        /// Same as every other panel's top bar plus its divider (SwiftUI bars are
        /// `panelHeaderHeight` + a 1pt Divider; this one draws its border inside),
        /// so the bottom borders line up.
        static let height: CGFloat = Theme.Metrics.panelHeaderHeight + Theme.Metrics.hairline
        static let gearSize: CGFloat = 11
    }

    /// White or near-black, whichever reads better on `color`.
    static func readableText(on color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.62 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    /// "Anna Berg" -> "AB", "claude" -> "C". Same rule as the Avatar view.
    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        let letters = parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Fill for a local branch badge.
    static func badgeFill(_ lane: NSColor) -> NSColor {
        lane.blended(withFraction: Badge.fillDarken, of: .black) ?? lane
    }
}

/// SF Symbol images, tinted and cached. Drawing a symbol per row is cheap
/// once the configured image exists.
@MainActor
enum GraphSymbols {
    private static var cache: [String: NSImage] = [:]

    /// `hierarchical` keeps cut-outs readable in ".fill" symbols (e.g. a check in a circle).
    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor,
                      hierarchical: Bool = false) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)|\(hierarchical)"
        if let hit = cache[key] { return hit }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(hierarchical ? .init(hierarchicalColor: color) : .init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        cache[key] = image
        return image
    }

    /// Draws the symbol centered vertically on `midY`, starting at `x`. Returns its width.
    @discardableResult
    static func draw(_ name: String, x: CGFloat, midY: CGFloat, size: CGFloat, color: NSColor,
                     weight: NSFont.Weight = .semibold, alpha: CGFloat = 1, hierarchical: Bool = false) -> CGFloat {
        guard let img = image(name, size: size, weight: weight, color: color, hierarchical: hierarchical) else { return 0 }
        let s = img.size
        img.draw(in: NSRect(x: x, y: midY - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        return s.width
    }

    static func width(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
        image(name, size: size, weight: weight, color: .labelColor)?.size.width ?? 0
    }
}
