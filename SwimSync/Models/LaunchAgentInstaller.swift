import Foundation

/// Makes the app open by itself when the player is plugged in.
///
/// launchd's `StartOnMount` fires on *any* volume mount, so the agent runs a
/// tiny guard script that opens the app only when the expected volume is
/// actually there. That is far more reliable than trying to keep a background
/// process alive to watch for the device.
enum LaunchAgentInstaller {
    static let label = "com.osamabedier.swimsync.mount"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var scriptURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/SwimSync/on-mount.sh")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install(volumeName: String, appPath: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let script = """
        #!/bin/bash
        # Installed by SwimSync. Opens the app when the MP3 player mounts.
        # launchd triggers this on every volume mount, so check it's ours first.
        VOL="/Volumes/\(volumeName)"
        for _ in 1 2 3 4 5; do
          if [ -d "$VOL" ]; then
            # Keep Spotlight off the device even before the app is up; indexing
            # it costs ~3x write throughput on a 12 Mbit/s link.
            touch "$VOL/.metadata_never_index" 2>/dev/null
            open -a "\(appPath)"
            exit 0
          fi
          sleep 1
        done
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", scriptURL.path],
            "StartOnMount": true,
            "RunAtLoad": false,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: plistURL)

        bootout()
        bootstrap()
    }

    static func uninstall() {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static func bootstrap() {
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func bootout() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
