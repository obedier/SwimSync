import SwiftUI

/// Capacity readout for the player. The incoming-selection segment is drawn
/// ahead of the used segment so you can see whether a batch will actually fit
/// before starting an 8-minute transfer.
struct DeviceCard: View {
    let device: Device
    let incoming: Int64

    private var usedFraction: Double { device.fractionUsed }
    private var incomingFraction: Double {
        device.totalBytes > 0
            ? min(1 - usedFraction, Double(incoming) / Double(device.totalBytes))
            : 0
    }
    private var overflows: Bool { incoming > device.freeBytes }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Theme.ok)
                            .frame(width: 7, height: 7)
                            .shadow(color: Theme.ok.opacity(0.7), radius: 4)
                        Text(device.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                    }
                    Text("USB full speed · ~1.1 MB/s ceiling")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.bytes(device.freeBytes))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    Text("free")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                }
            }

            capacityBar

            HStack {
                Label(Fmt.bytes(device.usedBytes), systemImage: "square.fill")
                    .foregroundStyle(Theme.textDim)
                if incoming > 0 {
                    Label(Fmt.bytes(incoming), systemImage: "square.fill")
                        .foregroundStyle(overflows ? Theme.warn : Theme.accent)
                }
                Spacer()
                Text(Fmt.bytes(device.totalBytes) + " total")
                    .foregroundStyle(Theme.textFaint)
            }
            .font(.system(size: 10.5))
            .labelStyle(DotLabel())

            if overflows {
                Text("Selection exceeds free space by \(Fmt.bytes(incoming - device.freeBytes)).")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.warn)
            }
        }
        .padding(16)
        .panel()
    }

    private var capacityBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bg)

                Capsule()
                    .fill(Theme.textDim.opacity(0.55))
                    .frame(width: max(0, w * usedFraction))

                Capsule()
                    .fill(overflows ? Theme.warn : Theme.accent)
                    .frame(width: max(0, w * incomingFraction))
                    .offset(x: w * usedFraction)
                    .animation(.easeOut(duration: 0.25), value: incomingFraction)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7))
            configuration.title
        }
    }
}
