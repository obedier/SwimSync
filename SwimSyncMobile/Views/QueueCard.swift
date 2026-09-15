import SwiftUI

struct QueueCard: View {
    let sendable: Set<String>
    /// Tracks the user has asked to send even though the player already has
    /// them; the existing copy is replaced.
    let forced: Set<String>
    let isOnDrive: (Track) -> Bool
    let onAdd: () -> Void
    let onToggleForce: (Track) -> Void

    @EnvironmentObject var library: MobileLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: "Queue", tint: Theme.library)
                Spacer()
                Button(action: onAdd) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .tint(Theme.library)
            }

            if library.queue.isEmpty {
                empty
            } else {
                VStack(spacing: 6) {
                    ForEach(library.queue) { track in
                        row(track)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 26, weight: .ultraLight))
                .foregroundStyle(Theme.textFaint)
            Text("Nothing queued")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textDim)
            // The Mac app reads the Podcasts folder directly; iOS cannot, and
            // saying so up front is kinder than an unexplained empty list.
            Text("Download episodes from the Find tab, add audio from Files, or share it to SwimSync from another app.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func row(_ track: Track) -> some View {
        let onDrive = isOnDrive(track)
        let willSend = sendable.contains(track.id)
        let isForced = forced.contains(track.id)

        return HStack(spacing: 10) {
            Image(systemName: statusIcon(onDrive: onDrive, willSend: willSend))
                .font(.system(size: 16))
                .foregroundStyle(statusTint(onDrive: onDrive, willSend: willSend))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(willSend ? Theme.text : Theme.textDim)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if !track.displayShow.isEmpty {
                        Text(track.displayShow).foregroundStyle(Theme.textFaint).lineLimit(1)
                    }
                    Text(Fmt.bytes(track.sizeBytes)).foregroundStyle(Theme.textFaint)
                    badges(track, onDrive: onDrive, isForced: isForced)
                }
                .font(.system(size: 11))
            }

            Spacer(minLength: 4)

            // A track the player already has can still be sent again — the
            // only way to fix a copy that landed but doesn't play.
            if onDrive && !track.isDRMProtected {
                Button {
                    onToggleForce(track)
                } label: {
                    Image(systemName: isForced ? "arrow.counterclockwise.circle.fill" : "arrow.counterclockwise.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isForced ? Theme.accent : Theme.textFaint.opacity(0.8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isForced ? "Don't replace on player" : "Replace on player")
            }

            Button {
                library.remove(track)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textFaint.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(willSend ? Color.white.opacity(0.03) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
    }

    @ViewBuilder
    private func badges(_ track: Track, onDrive: Bool, isForced: Bool) -> some View {
        if track.isDRMProtected {
            TrackBadge(text: "copy-protected", tint: Theme.warn)
        } else if onDrive && isForced {
            TrackBadge(text: "will replace", tint: Theme.accent)
        } else if onDrive {
            TrackBadge(text: "on player", tint: Theme.ok)
        }
        if !track.isLikelyPlayable && !track.isDRMProtected {
            TrackBadge(text: track.format.uppercased(), tint: Theme.warn)
        }
        if track.hasOpaqueName && !track.isDRMProtected {
            TrackBadge(text: "will be renamed", tint: Theme.accent)
        }
    }

    private func statusIcon(onDrive: Bool, willSend: Bool) -> String {
        if willSend { return "arrow.up.circle.fill" }
        return onDrive ? "checkmark.circle" : "minus.circle"
    }

    private func statusTint(onDrive: Bool, willSend: Bool) -> Color {
        if willSend { return Theme.library }
        return onDrive ? Theme.ok.opacity(0.6) : Theme.textFaint.opacity(0.5)
    }
}

/// Small status marker used inside queue rows.
struct TrackBadge: View {
    let text: String
    var tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.16))
            .clipShape(Capsule())
    }
}
