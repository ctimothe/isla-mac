import Foundation
import os

/// Sends playback commands (play/pause/next/previous) via the same vendored
/// mediaremote-adapter script used for reading now-playing state — it exposes
/// a `send COMMAND` mode per checklist.md, so this reuses the one vetted,
/// BSD-3-Clause dependency (locked decision #5) rather than hand-rolling a
/// second, separate dlopen of MediaRemote's private command functions with
/// unverified command constants.
public actor MediaRemoteCommandSender {
    public enum Command: String, Sendable {
        case play, pause, next = "nexttrack", previous = "previoustrack"
    }

    private static let logger = Logger(subsystem: "DynamicIsland", category: "MediaRemoteCommandSender")
    private let bundle: Bundle

    public init(bundle: Bundle) {
        self.bundle = bundle
    }

    public func send(_ command: Command) {
        guard
            let scriptURL = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: "mediaremote-adapter"),
            let frameworkURL = bundle.url(forResource: "MediaRemoteAdapter", withExtension: "framework", subdirectory: "mediaremote-adapter")
        else {
            Self.logger.error("MediaRemoteCommandSender: vendored adapter resources missing from bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "send", command.rawValue]
        do {
            try process.run()
        } catch {
            Self.logger.error("MediaRemoteCommandSender: failed to send \(command.rawValue, privacy: .public): \(String(describing: error))")
        }
    }
}
