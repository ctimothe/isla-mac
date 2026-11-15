import Foundation

/// The source of one type, read across its main file and every `Type+Concern.swift`
/// extension file beside it, so a test that pins a line of code keeps holding
/// it when the code moves between a type's files.
enum SourceText {
    /// `path` is the main file's repo-relative path
    /// (`Sources/IslaKit/Notch/NotchController.swift`). The result is that
    /// file's text followed by each `NotchController+*.swift` in the same
    /// folder, sorted by name, separated by newlines.
    static func of(_ path: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let main = root.appendingPathComponent(path)
        let folder = main.deletingLastPathComponent()
        let stem = main.deletingPathExtension().lastPathComponent
        let extensions = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(stem + "+") && $0.hasSuffix(".swift") }
            .sorted()
        return try ([main] + extensions.map { folder.appendingPathComponent($0) })
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
