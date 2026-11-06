import SwiftUI

/// Sizes and fonts for the window chrome: toolbar, status bar, welcome screen.
enum ChromeStyle {
    /// Picker captions and toolbar button titles.
    static let caption = Font.system(size: 10)
    static let icon = Font.system(size: 15)
    /// Badge position on a toolbar icon: over its top-right corner, never above the icon.
    static let badgeOffset = CGSize(width: 8, height: -2)

    static let iconHeight: CGFloat = 18
    static let buttonMinWidth: CGFloat = 40
    static let chevronPadding: CGFloat = 2
    static let dividerHeight: CGFloat = 28

    // Center mode switch (History | Board | Reviews)
    static let segment = Font.system(size: 11, weight: .medium)
    static let segmentSymbol = Font.system(size: 10, weight: .semibold)
    static let segmentHeight: CGFloat = 22
    static let segmentInset: CGFloat = 2
    static let segmentTrackFill = 0.06
    static let segmentSelectedFill = 0.18

    static let tileIcon = Font.system(size: 18)
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
            Text(ui: title)
                .font(ChromeStyle.caption)
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
        .buttonStyle(HoverFillStyle.chrome())
        .disabled(disabled)
        .help(Text(ui: help ?? title))
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
                    .font(Theme.Glyph.dropdown)
                    .frame(height: ChromeStyle.iconHeight)
            }
            .menuStyle(.button)
            .buttonStyle(HoverFillStyle.chrome(horizontalPadding: ChromeStyle.chevronPadding))
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(disabled)
            .help("More \(L(title)) options")
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
                Text(ui: caption)
                    .font(ChromeStyle.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.s) {
                    Text(title)
                        .font(Theme.Font.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(Theme.Glyph.dropdown)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(HoverFillStyle.chrome())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(ui: help ?? caption))
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
