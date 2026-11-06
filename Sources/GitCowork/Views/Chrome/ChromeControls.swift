import SwiftUI

/// Sizes and fonts for the window chrome: toolbar, status bar, welcome screen.
enum ChromeStyle {
    static let caption = Font.system(size: 10)
    static let pickerTitle = Font.system(size: 13, weight: .semibold)
    static let pickerChevron = Theme.Glyph.dropdown
    static let icon = Font.system(size: 15)
    static let label = Font.system(size: 10)
    /// Badge position on a toolbar icon: over its top-right corner, never above the icon.
    static let badgeOffset = CGSize(width: 8, height: -2)
    static let menuChevron = Theme.Glyph.dropdown

    static let iconHeight: CGFloat = 18
    static let buttonMinWidth: CGFloat = 40
    static let buttonPadding = EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
    static let chevronPadding: CGFloat = 2
    static let dividerHeight: CGFloat = 28
    /// Same as a list row, so the bar lines up with panel content above it.
    static let statusBarHeight: CGFloat = Theme.Metrics.rowHeight

    // Center mode switch (History | Board | Reviews)
    static let segment = Font.system(size: 11, weight: .medium)
    static let segmentSymbol = Font.system(size: 10, weight: .semibold)
    static let segmentHeight: CGFloat = 22
    static let segmentInset: CGFloat = 2
    static let segmentTrackFill = 0.06
    static let segmentSelectedFill = 0.18

    static let hoverFill = 0.08
    static let pressedFill = 0.16
    static let tileIcon = Font.system(size: 18)
}

/// Flat toolbar button look: no bezel, a soft fill on hover and press.
struct ChromeButtonStyle: ButtonStyle {
    var horizontalPadding = ChromeStyle.buttonPadding.leading

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, horizontalPadding: horizontalPadding)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let horizontalPadding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .padding(.vertical, ChromeStyle.buttonPadding.top)
                .padding(.horizontal, horizontalPadding)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control).fill(Color.primary.opacity(fill)))
                .foregroundStyle(enabled ? .primary : .tertiary)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Double {
            guard enabled else { return 0 }
            if configuration.isPressed { return ChromeStyle.pressedFill }
            return hovering ? ChromeStyle.hoverFill : 0
        }
    }
}

/// Icon above a small label, with an optional count badge on the icon.
struct ChromeButtonLabel: View {
    let title: String
    let symbol: String
    var badge = 0
    var minWidth: CGFloat = ChromeStyle.buttonMinWidth

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Image(systemName: symbol)
                .font(ChromeStyle.icon)
                .frame(height: ChromeStyle.iconHeight)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 { CountBadge(count: badge, style: .toolbar).offset(x: ChromeStyle.badgeOffset.width, y: ChromeStyle.badgeOffset.height) }
                }
            Text(title)
                .font(ChromeStyle.label)
        }
        .frame(minWidth: minWidth)
    }
}

/// "Branch", "Stash", "Terminal"… in the toolbar.
struct ChromeButton: View {
    let title: String
    let symbol: String
    var badge = 0
    var help: String?
    var disabled = false
    var minWidth: CGFloat = ChromeStyle.buttonMinWidth
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChromeButtonLabel(title: title, symbol: symbol, badge: badge, minWidth: minWidth)
        }
        .buttonStyle(ChromeButtonStyle())
        .disabled(disabled)
        .help(help ?? title)
    }
}

/// Toolbar button with a ▾ right beside the icon for variants (Pull ▾, Push ▾).
/// The main button keeps its natural width so the caret hugs the glyph.
struct ChromeSplitButton<Items: View>: View {
    let title: String
    let symbol: String
    var badge = 0
    var help: String?
    var disabled = false
    let action: () -> Void
    @ViewBuilder var items: Items

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ChromeButton(title: title, symbol: symbol, badge: badge, help: help, disabled: disabled,
                         minWidth: 0, action: action)
            Menu { items } label: {
                Image(systemName: "chevron.down")
                    .font(ChromeStyle.menuChevron)
                    .frame(height: ChromeStyle.iconHeight)
            }
            .menuStyle(.button)
            .buttonStyle(ChromeButtonStyle(horizontalPadding: ChromeStyle.chevronPadding))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(disabled)
            .help("More \(title) options")
        }
        .fixedSize()
    }
}

/// GitKraken-style picker: small grey caption above a bold value with ▾.
struct StackedPicker<Items: View>: View {
    let caption: String
    let title: String
    var help: String?
    @ViewBuilder var items: Items

    var body: some View {
        Menu { items } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(caption)
                    .font(ChromeStyle.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    Text(title)
                        .font(ChromeStyle.pickerTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(ChromeStyle.pickerChevron)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(ChromeButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help ?? caption)
    }
}

/// Thin vertical rule between toolbar groups.
struct ChromeDivider: View {
    var body: some View {
        Divider()
            .frame(height: ChromeStyle.dividerHeight)
            .padding(.horizontal, Theme.Space.s)
    }
}

/// Compact segmented switch for the middle area: History | Board | Reviews.
struct CenterModeSwitch: View {
    let model: RepoModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(CenterMode.allCases.enumerated()), id: \.element) { i, mode in
                Segment(mode: mode, selected: model.centerMode == mode) {
                    model.openDiff = nil
                    model.centerMode = mode
                }
                .help("\(mode.title) (⌘\(i + 1))")
            }
        }
        .padding(ChromeStyle.segmentInset)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control + ChromeStyle.segmentInset)
            .fill(Color.primary.opacity(ChromeStyle.segmentTrackFill)))
        .fixedSize()
    }

    private struct Segment: View {
        let mode: CenterMode
        let selected: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: mode.symbol).font(ChromeStyle.segmentSymbol)
                    Text(mode.title).font(ChromeStyle.segment)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: ChromeStyle.segmentHeight)
                .foregroundStyle(selected ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Color.accentColor.opacity(selected ? ChromeStyle.segmentSelectedFill : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}
