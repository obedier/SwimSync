import SwiftUI

struct TrackRow: View {
    let track: Track
    let isSelected: Bool
    let isOnDevice: Bool
    var tint: Color = Theme.library
    let toggle: () -> Void

    @State private var hovering = false

    private var isSelectable: Bool { !track.isDRMProtected }

    var body: some View {
        Button(action: { if isSelectable { toggle() } }) {
            HStack(spacing: 11) {
                marker

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.displayTitle)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelectable ? Theme.text : Theme.textFaint)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if !track.displayShow.isEmpty {
                            Text(track.displayShow)
                                .foregroundStyle(Theme.textDim)
                                .lineLimit(1)
                        }
                        badges
                    }
                    .font(.system(size: 10.5))
                }

                Spacer(minLength: 8)

                Text(Fmt.duration(track.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textFaint)
                Text(Fmt.bytes(track.sizeBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(track.isDRMProtected ? "Apple Music download — copy-protected, cannot be transferred" : "")
    }

    @ViewBuilder
    private var marker: some View {
        if track.isDRMProtected {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textFaint.opacity(0.7))
                .frame(width: 15)
        } else if isOnDevice {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 15))
                .foregroundStyle(Theme.ok.opacity(0.55))
        } else {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? tint : Theme.textFaint.opacity(0.6))
        }
    }

    @ViewBuilder
    private var badges: some View {
        if isOnDevice {
            TrackBadge(text: "on player", tint: Theme.ok)
        }
        if !track.isLikelyPlayable && !track.isDRMProtected {
            TrackBadge(text: track.format.uppercased(), tint: Theme.warn)
        }
        if track.hasOpaqueName && !track.isDRMProtected {
            TrackBadge(text: "will be renamed", tint: Theme.accent)
        }
    }

    private var rowBackground: Color {
        if isSelected { return tint.opacity(0.13) }
        if hovering && isSelectable { return Color.white.opacity(0.045) }
        return .clear
    }
}
