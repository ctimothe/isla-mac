import Foundation
import os

/// Spawns the vendored mediaremote-adapter perl script (bundled with this app,
/// see plan section 1 — vendoring, and checklist.md's Music section for why
/// this indirection through /usr/bin/perl is the only working read-path as of
/// macOS 15.4+) and streams parsed now-playing updates.
///
/// Modeled as an actor to keep the Pipe `readabilityHandler` callback and the
/// line buffer race-free under Swift 6 strict concurrency.
public actor MediaRemoteAdapterClient {
    private static let logger = Logger(subsystem: "DynamicIsland", category: "MediaRemoteAdapterClient")

    private let bundle: Bundle
    private var process: Process?
    private var lineBuffer = NDJSONLineBuffer()
    private let continuation: AsyncStream<NowPlayingInfo>.Continuation
    public let stream: AsyncStream<NowPlayingInfo>

    public init(bundle: Bundle) {
        self.bundle = bundle
        var continuation: AsyncStream<NowPlayingInfo>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard
            let scriptURL = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: "mediaremote-adapter"),
            let frameworkURL = bundle.url(forResource: "MediaRemoteAdapter", withExtension: "framework", subdirectory: "mediaremote-adapter")
        else {
            Self.logger.error("MediaRemoteAdapterClient: vendored adapter resources missing from bundle")
            continuation.finish()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "stream"]

        let pipe = Pipe()
        process.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.finish() }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            Self.logger.error("MediaRemoteAdapterClient: perl subprocess failed to launch: \(String(describing: error))")
            continuation.finish()
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
    }

    private func ingest(_ chunk: Data) {
        for line in lineBuffer.append(chunk) {
            if let info = try? JSONDecoder().decode(NowPlayingInfo.self, from: line) {
                continuation.yield(info)
            } else {
                Self.logger.error("MediaRemoteAdapterClient: failed to decode a line, skipping")
            }
        }
    }

    private func finish() {
        continuation.finish()
    }
}
