import Foundation
import XCTest
@testable import IslaKit

/// The real downloader against a stubbed wire: the status check, the size cap, the
/// redirect rule and the cleanup, with the delegate and the session that run in
/// the app.
final class UpdateDownloaderTests: XCTestCase {
    private let url = URL(string: "https://github.com/ctimothe/isla-mac/releases/download/v1.1/Isla-1.1.dmg")!

    override func tearDown() { StubGitHub.clear() }

    private var downloader: URLSessionUpdateDownloader {
        var downloader = URLSessionUpdateDownloader()
        downloader.makeSession = StubGitHub.session
        return downloader
    }

    private func attempt(
        _ folder: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async -> Result<URL, Error> {
        do { return .success(try await downloader.download(from: url, into: folder, as: "Isla.dmg", expectedBytes: expected, progress: progress)) }
        catch { return .failure(error) }
    }

    private func files(_ folder: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64] = []
        func note(_ value: Int64) { lock.withLock { values.append(value) } }
        var all: [Int64] { lock.withLock { values } }
    }

    func testAnImageIsDownloadedWithProgress() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let data = Data((0..<200_000).map { UInt8($0 % 251) })
        StubGitHub.serve(url, data)
        let progress = Progress()
        let result = await attempt(folder, expected: Int64(data.count)) { progress.note($0) }
        let file = try result.get()
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(file.lastPathComponent, "Isla.dmg")
        XCTAssertFalse(progress.all.isEmpty)
        XCTAssertEqual(progress.all, progress.all.sorted(), "progress only moves forward")
    }

    /// A server that sends more than the release said: stopped, and nothing kept.
    func testABodyLargerThanAdvertisedIsRefusedAndDeleted() async throws {
        let folder = try UpdateTestSupport.folder(self)
        StubGitHub.serve(url, Data(repeating: 1, count: 300_000))
        let result = await attempt(folder, expected: 100_000)
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? UpdateDownloadError, .tooLarge) }
        XCTAssertEqual(files(folder), [], "no partial file is left")
    }

    func testABodyThatIsExactlyTheAdvertisedSizeIsAccepted() async throws {
        let folder = try UpdateTestSupport.folder(self)
        StubGitHub.serve(url, Data(repeating: 1, count: 100_000))
        let result = await attempt(folder, expected: 100_000)
        XCTAssertNoThrow(try result.get())
    }

    func testAnAnswerThatIsNotA200IsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        for code in [404, 403, 500, 206] {
            StubGitHub.answer(url, .status(code))
            let result = await attempt(folder, expected: 100)
            XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? UpdateDownloadError, .badStatus(code)) }
            XCTAssertEqual(files(folder), [])
        }
    }

    /// GitHub serves assets from another host, and that redirect is followed.
    func testAnHTTPSRedirectIsFollowed() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let cdn = URL(string: "https://objects.githubusercontent.com/release-asset/Isla-1.1.dmg")!
        StubGitHub.answer(url, .redirect(to: cdn))
        StubGitHub.serve(cdn, Data(repeating: 7, count: 5_000))
        let result = await attempt(folder, expected: 5_000)
        XCTAssertEqual(try Data(contentsOf: result.get()).count, 5_000)
        XCTAssertEqual(StubGitHub.requested, [url, cdn])
    }

    /// A redirect to plain http is never followed: the request for it is never made.
    func testAnHTTPRedirectIsRefusedEndToEnd() async throws {
        let folder = try UpdateTestSupport.folder(self)
        let plain = URL(string: "http://objects.githubusercontent.com/release-asset/Isla-1.1.dmg")!
        StubGitHub.answer(url, .redirect(to: plain))
        StubGitHub.serve(plain, Data(repeating: 7, count: 5_000))
        let result = await attempt(folder, expected: 5_000)
        XCTAssertThrowsError(try result.get(), "the downgrade must fail, not download")
        XCTAssertFalse(StubGitHub.requested.contains(plain), "and the insecure URL is never even asked for")
        XCTAssertEqual(files(folder), [])
    }

    func testARedirectToAFileURLIsRefused() async throws {
        let folder = try UpdateTestSupport.folder(self)
        StubGitHub.answer(url, .redirect(to: URL(string: "file:///etc/hosts")!))
        let result = await attempt(folder, expected: 5_000)
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(files(folder), [])
    }
}
