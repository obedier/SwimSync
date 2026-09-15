import SwiftUI

struct PlayerCard: View {
    let onChoose: () -> Void
    /// Asked to erase every track on the player. The caller owns the
    /// confirmation; this card only offers the button.
    let onErase: () -> Void

    @EnvironmentObject var drive: DriveStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Player", tint: Theme.accent)

            if let device = drive.device {
                connected(device)
            } else {
                disconnected
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - Connected

    private func connected(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(device.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(drive.contents.count) track\(drive.contents.count == 1 ? "" : "s")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }

            // Always state the destination. Getting this wrong is silent and
            // looks exactly like a successful transfer.
            Label(drive.destinationDescription, systemImage: drive.isExternal ? "externaldrive.fill" : "iphone")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(drive.isExternal ? Theme.textFaint : Theme.warn)

            if !drive.isExternal { onPhoneWarning }

            if device.totalBytes > 0 && drive.isExternal {
                capacityBar(device)
            } else if drive.isExternal {
                Text("Connected — this drive doesn't report its capacity.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textFaint)
            }

            HStack {
                Button("Change folder", action: onChoose)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                Spacer()

                // Only for a real drive with something on it. Erasing the
                // phone's own folder would delete the downloads instead.
                if drive.isExternal && !drive.contents.isEmpty {
                    Button("Erase player…", action: onErase)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.warn)
                }
            }
        }
    }

    /// The trap this app sets for itself: its own Documents folder is published
    /// to Files under the app's name, one row away from the real drive.
    private var onPhoneWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warn)
                VStack(alignment: .leading, spacing: 3) {
                    Text(drive.isOwnDocuments
                         ? "That's SwimSync's own folder, not the player"
                         : "That folder is on this iPhone, not the player")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Files copied here stay on the phone. In the picker, tap **Browse** and choose the drive under **Locations** — not **On My iPhone**.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onChoose) {
                Text("Pick the drive instead")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.warn)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            }
        }
        .padding(11)
        .background(Theme.warn.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
    }

    private func capacityBar(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.bg)
                    Capsule()
                        .fill(Theme.accent.opacity(0.85))
                        .frame(width: max(3, geo.size.width * device.fractionUsed))
                }
            }
            .frame(height: 7)

            HStack {
                Text("\(Fmt.bytes(device.usedBytes)) used")
                Spacer()
                Text("\(Fmt.bytes(device.freeBytes)) free")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.textFaint)
        }
    }

    // MARK: - Disconnected

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No player selected")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textDim)
                    Text("Plug the player into this iPhone, then pick it in Files.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onChoose) {
                Text("Choose Player Folder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            }

            // iOS gives an app no way to discover volumes on its own, so the
            // one-time hand-off through Files is worth spelling out.
            Text("In the picker, tap **Browse** and look under **Locations** for the drive.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
