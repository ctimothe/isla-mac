import CryptoKit
import Foundation
import XCTest
@testable import IslaKit

/// Everything the update tests build in a folder of their own: a throwaway
/// folder that is removed afterwards, tiny apps with a bundle identifier and
/// versions, an Ed25519 key, and a way to run a system tool.
///
/// Nothing here reaches outside the folder it is given. The apps are copies of
/// `/usr/bin/true` under an Info.plist, ad-hoc signed with `codesign -s -` when
/// a test asks for a signature, never installed anywhere and never launched.
enum UpdateTestSupport {
    static func folder(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-update-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock {
            // A test may leave a read-only folder behind on purpose.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    enum Signing { case none, adHoc }

    @discardableResult
    static func tinyApp(
        in folder: URL, name: String = "Isla.app", bundleID: String = "com.ctimothe.isla",
        version: String, build: String, signing: Signing = .adHoc, marker: String = ""
    ) throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Contents/MacOS/Isla"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "Isla", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
        ]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: app.appendingPathComponent("Contents/Resources/marker.txt"))
        if signing == .adHoc {
            let (status, output) = run("/usr/bin/codesign", ["--force", "-s", "-", app.path])
            guard status == 0 else { throw NSError(domain: "codesign", code: Int(status), userInfo: [NSLocalizedDescriptionKey: output]) }
        }
        return app
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// A stable fingerprint of a folder's contents and layout: every relative
    /// path with its bytes, so "untouched" means byte-identical.
    static func fingerprint(of root: URL) -> String {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return "missing" }
        var lines: [String] = []
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(root.path.count))
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                lines.append("L \(relative) -> \((try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?")")
            } else if values?.isDirectory == true {
                lines.append("D \(relative)")
            } else {
                let data = (try? Data(contentsOf: url)) ?? Data()
                lines.append("F \(relative) \(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())")
            }
        }
        return lines.sorted().joined(separator: "\n")
    }

    /// A key pair made here, with the two halves as base64 the way the release
    /// script prints them.
    struct Key {
        let privateKey = Curve25519.Signing.PrivateKey()
        var publicBase64: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }

        func sign(_ data: Data) -> String {
            try! privateKey.signature(for: data).base64EncodedString()
        }
    }
}
