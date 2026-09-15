import SwiftUI
import AppKit

struct DevicePane: View {
    let selectedCount: Int
    let selectedBytes: Int64
    @Binding var numberTracks: Bool
    @Binding var useMetadataNames: Bool
    let onTransfer: () -> Void

    @EnvironmentObject var monitor: DeviceMonitor
    @EnvironmentObject var transfer: TransferEngine

    @State private var autoOpen = LaunchAgentInstaller.isInstalled
    @State private var showContents = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(text: "Device", tint: Theme.accent)

                    if let device = monitor.device {
                        DeviceCard(device: device, incoming: selectedBytes)
                        if transfer.isRunning || transfer.finishedSummary != nil {
                            TransferPanel()
                        }
                        options
                        contentsSection(device)
                    } else {
                        disconnected
                    }
                }
                .padding(20)
            }

            Divider().overlay(Theme.hairline)
            actionBar
        }
        .background(Theme.bg)
    }

    // MARK: - Disconnected

    private var disconnected: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(Theme.textFaint)
            Text("Player not connected")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textDim)
            Text("Plug in the magnetic cable. SwimSync picks it up automatically.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Rescan") { monitor.refresh() }
                .buttonStyle(PillButton(tint: Theme.textDim))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .panel()
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "On transfer")

            Toggle(isOn: $numberTracks) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Number tracks in order").font(.system(size: 12))
                    Text("These players sort by filename, so `01 - ` keeps your queue order.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $useMetadataNames) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name from ID3 tags").font(.system(size: 12))
                    Text("Podcast downloads arrive as UUIDs; this gives them real titles.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $autoOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open when player connects").font(.system(size: 12))
                    Text("Installs a login agent that launches SwimSync on mount.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: autoOpen) { _, on in setAutoOpen(on) }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .padding(16)
        .panel()
    }

    // MARK: - Device contents

    private func contentsSection(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showContents.toggle() }
            } label: {
                HStack {
                    SectionLabel(text: "On the player · \(monitor.contents.count)")
                    Spacer()
                    Image(systemName: showContents ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textFaint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showContents {
                if monitor.contents.isEmpty {
                    Text("Empty").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                } else {
                    VStack(spacing: 1) {
                        ForEach(monitor.contents) { item in
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.bytes(item.sizeBytes))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textFaint)
                                Button {
                                    monitor.delete(item)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.warn.opacity(0.85))
                                }
                                .buttonStyle(.plain)
                                .help("Delete from player")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .padding(16)
        .panel()
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 9) {
            if selectedCount > 0 && !transfer.isRunning {
                HStack {
                    Text("\(selectedCount) selected · \(Fmt.bytes(selectedBytes))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("~\(Fmt.eta(bytes: selectedBytes))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
            }

            HStack(spacing: 9) {
                if transfer.isRunning {
                    Button("Cancel") { transfer.cancel() }
                        .buttonStyle(PillButton(tint: Theme.warn))
                } else {
                    Button {
                        onTransfer()
                    } label: {
                        Text(selectedCount > 0 ? "Transfer \(selectedCount)" : "Transfer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(monitor.device == nil || selectedCount == 0)
                }

                Button {
                    monitor.eject()
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(PillButton(tint: Theme.textDim))
                .disabled(monitor.device == nil || transfer.isRunning)
                .help("Flush, clean, and eject")
            }
        }
        .padding(16)
    }

    private func setAutoOpen(_ on: Bool) {
        if on {
            let path = Bundle.main.bundlePath
            let name = monitor.device?.name ?? monitor.preferredName
            try? LaunchAgentInstaller.install(volumeName: name, appPath: path)
        } else {
            LaunchAgentInstaller.uninstall()
        }
        autoOpen = LaunchAgentInstaller.isInstalled
    }
}
