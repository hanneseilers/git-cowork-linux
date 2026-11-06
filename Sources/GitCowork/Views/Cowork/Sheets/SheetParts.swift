import SwiftUI

/// Label column + field, for the grids in the cowork sheets.
struct SheetRow<Content: View>: View {
    let label: String
    /// Use for tall fields (lists, text editors): the label sits at their first line.
    var top = false
    @ViewBuilder var content: Content

    var body: some View {
        GridRow(alignment: top ? .top : .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .padding(.top, top ? 5 : 0)
                .gridColumnAlignment(.trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Grid with the spacing every cowork sheet uses.
struct SheetGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.m + 2) {
            content
        }
    }
}

/// Inline note with an icon: warnings and hints inside sheets.
struct SheetNotice<Trailing: View>: View {
    let symbol: String
    let color: Color
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
                .font(Theme.Font.small)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing
        }
        .padding(Theme.Metrics.cardPadding)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
    }
}
