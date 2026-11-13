import Foundation
// The VBAN wire format, theme and controls shared with the Grabber. Re-exported so every file
// here sees them.
@_exported import NetworkAudioShared

/// The Sender's entry point. Its code is a library, so the Grabber's Send area is
/// built from the Sender's own state and views; the app's executable only calls this.
public enum SenderEntry {
    public static func main() {
        // `--selftest` sends without a window, for checking the capture and transmit path from the
        // terminal. `--render` draws the window to images. Everything else launches the app.
        if CommandLine.arguments.contains("--protocol-vectors") {
            // docs/PROTOCOL.md's sample packets, from the real encoders.
            print(ProtocolVectors.markdown(), terminator: "")
            if CommandLine.arguments.contains("--swift") {
                for v in ProtocolVectors.all { print("        \"\(v.label)\": \"\(ProtocolVectors.hex(v.bytes))\",") }
            }
        } else if CommandLine.arguments.contains("--checkdefaults") {
            SenderDefaultsCheck.run()
        } else if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SenderSelfTest.run(arguments: CommandLine.arguments) }
        } else if CommandLine.arguments.contains("--render") {
            MainActor.assumeIsolated { SenderRender.run(arguments: CommandLine.arguments) }
        } else {
            NetworkAudioSenderApp.main()
        }
    }
}
