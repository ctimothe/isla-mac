import Foundation

struct AppPaths: Sendable {
    let supportDirectory: URL
    let screenshotDirectory: URL

    static let live: AppPaths = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProductIdentity.supportDirectoryName, isDirectory: true)
        let screenshots = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(ProductIdentity.screenshotDirectoryName, isDirectory: true)
        return AppPaths(supportDirectory: support, screenshotDirectory: screenshots)
    }()

    func ensureSupportDirectory(using fm: FileManager = .default) throws {
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    func supportFile(_ name: String, using fm: FileManager = .default) -> URL {
        try? ensureSupportDirectory(using: fm)
        return supportDirectory.appendingPathComponent(name)
    }
}
