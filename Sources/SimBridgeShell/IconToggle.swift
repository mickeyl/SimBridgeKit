import SwiftUI

/// A label-less preference toggle for the panel footer. The on state is shown
/// three ways so it stays unambiguous without text: filled glyph, accent tint,
/// and a tinted background pill. The meaning lives in the tooltip and
/// accessibility label.
public struct IconToggle: View {
    private let systemImage: String
    private let help: String
    @Binding private var isOn: Bool

    public init(systemImage: String, help: String, isOn: Binding<Bool>) {
        self.systemImage = systemImage
        self.help = help
        self._isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .symbolVariant(isOn ? .fill : .none)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.15) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
