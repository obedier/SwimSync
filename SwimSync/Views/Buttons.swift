import SwiftUI

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(enabled ? Color.black.opacity(0.88) : Theme.textFaint)
            .padding(.vertical, 9)
            .background(enabled ? Theme.accent.opacity(configuration.isPressed ? 0.75 : 1) : Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }
}

struct PillButton: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(tint.opacity(configuration.isPressed ? 0.30 : 0.16))
            .clipShape(Capsule())
    }
}

/// A toggle that reads as a filter rather than a switch — it states what it is
/// currently doing to the list, so an empty-looking library is always explained.
struct FilterChip: View {
    let label: String
    let icon: String
    var tint: Color = Theme.library
    @Binding var isOn: Bool

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOn.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? icon : "circle.dashed")
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isOn ? tint : Theme.textFaint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(isOn ? tint.opacity(0.15) : Color.white.opacity(hovering ? 0.05 : 0.02))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(isOn ? tint.opacity(0.35) : Theme.hairline, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Small status marker used inside track rows.
struct TrackBadge: View {
    let text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.16))
            .clipShape(Capsule())
    }
}
