import Foundation
import XCTest
@testable import IslaKit

/// `HdiutilDiskImage` over a scripted `hdiutil`: which device it detaches on each
/// way an attach can go wrong, and that it never gives up on a volume quietly.
final class UpdateDiskImageTests: XCTestCase {
    private final class Script: @unchecked Sendable {
        struct Call: Equatable { let arguments: [String] }
        private let lock = NSLock()
        private var answers: [([String]) -> UpdateTool.Result?]
        private(set) var calls: [Call] = []
        private(set) var timeouts: [TimeInterval] = []

        init(_ answers: [([String]) -> UpdateTool.Result?]) { self.answers = answers }

        func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) async -> UpdateTool.Result? {
            let answer: ([String]) -> UpdateTool.Result? = lock.withLock {
                calls.append(Call(arguments: arguments))
                timeouts.append(timeout)
                return answers.isEmpty ? { _ in nil } : answers.removeFirst()
            }
            return answer(arguments)
        }

        var detaches: [[String]] { calls.map(\.arguments).filter { $0.first == "detach" } }
    }

    private let image = URL(fileURLWithPath: "/tmp/scratch/Isla.dmg")
    private let scratch = URL(fileURLWithPath: "/tmp/scratch")

    private func plist(mounts: [String], devices: [String] = ["/dev/disk9", "/dev/disk9s1"]) -> Data {
        var entities = devices.map { "<dict><key>dev-entry</key><string>\($0)</string></dict>" }
        for mount in mounts {
            entities.append("<dict><key>dev-entry</key><string>/dev/disk9s2</string><key>mount-point</key><string>\(mount)</string></dict>")
        }
        return Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>system-entities</key><array>\(entities.joined())</array></dict></plist>".utf8)
    }

    private func info(device: String, imagePath: String) -> Data {
        Data("""
        <?xml version="1.0"?><plist version="1.0"><dict><key>images</key><array>
        <dict><key>image-path</key><string>/tmp/other.dmg</string><key>system-entities</key><array><dict><key>dev-entry</key><string>/dev/disk5</string></dict></array></dict>
        <dict><key>image-path</key><string>\(imagePath)</string><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>\(device)</string></dict><dict><key>dev-entry</key><string>\(device)s1</string></dict></array></dict>
        </array></dict></plist>
        """.utf8)
    }

    private func ok(_ data: Data = Data()) -> ([String]) -> UpdateTool.Result? { { _ in .init(status: 0, output: data, timedOut: false) } }
    private func failed() -> ([String]) -> UpdateTool.Result? { { _ in .init(status: 1, output: Data(), timedOut: false) } }
    private func timedOut() -> ([String]) -> UpdateTool.Result? { { _ in .init(status: -15, output: Data(), timedOut: true) } }

    private func disk(_ script: Script) -> HdiutilDiskImage {
        HdiutilDiskImage(run: script.run, retryDelay: 0)
    }

    func testAnAttachReturnsTheMountAndItsWholeDisk() async throws {
        let script = Script([ok(plist(mounts: ["/tmp/scratch/dmg.abc"]))])
        let mount = try await disk(script).attach(image, scratch: scratch)
        XCTAssertEqual(mount.mountPoint.path, "/tmp/scratch/dmg.abc")
        XCTAssertEqual(mount.devices, ["/dev/disk9"], "the whole disk, which takes its partitions with it")
        XCTAssertEqual(script.detaches, [])
    }

    func testExitZeroWithNoMountPointDetachesTheDeviceItAttached() async throws {
        let script = Script([ok(plist(mounts: [])), ok()])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? UpdateImageError, .noMountPoint)
        }
        XCTAssertEqual(script.detaches, [["detach", "-force", "/dev/disk9"]])
    }

    func testTwoVolumesAreBothDetached() async throws {
        let script = Script([ok(plist(mounts: ["/tmp/scratch/dmg.a", "/tmp/scratch/dmg.b"], devices: ["/dev/disk9"])), ok()])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? UpdateImageError, .oneVolumeExpected)
        }
        XCTAssertEqual(script.detaches, [["detach", "-force", "/dev/disk9"]])
    }

    func testAnAttachThatTimedOutAfterMountingIsFoundByItsImagePathAndDetached() async throws {
        let script = Script([timedOut(), ok(info(device: "/dev/disk7", imagePath: "/tmp/scratch/Isla.dmg")), ok()])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? UpdateImageError, .attachFailed)
        }
        XCTAssertEqual(script.calls.map { $0.arguments.first }, ["attach", "info", "detach"])
        XCTAssertEqual(script.detaches, [["detach", "-force", "/dev/disk7"]], "only this image's device, not the other one listed")
    }

    func testAnAttachThatFailedAndLeftNothingDetachesNothing() async throws {
        let script = Script([failed(), ok(info(device: "/dev/disk7", imagePath: "/tmp/elsewhere.dmg"))])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? UpdateImageError, .attachFailed)
        }
        XCTAssertEqual(script.detaches, [])
    }

    func testDetachTriesThreeTimesThenSaysItIsStillThere() async throws {
        let script = Script([failed(), failed(), failed(), ok()])
        let gone = await disk(script).detach(UpdateMount(mountPoint: scratch, devices: ["/dev/disk9"]))
        XCTAssertFalse(gone)
        XCTAssertEqual(script.detaches.count, 3, "three tries and no more")
        XCTAssertTrue(script.detaches.allSatisfy { $0 == ["detach", "-force", "/dev/disk9"] })
    }

    func testDetachSucceedsOnALaterTry() async throws {
        let script = Script([failed(), timedOut(), ok()])
        let gone = await disk(script).detach(UpdateMount(mountPoint: scratch, devices: ["/dev/disk9"]))
        XCTAssertTrue(gone)
        XCTAssertEqual(script.detaches.count, 3)
    }

    func testAMountWithNoDeviceIsDetachedByItsMountPoint() async throws {
        let script = Script([ok()])
        let gone = await disk(script).detach(UpdateMount(mountPoint: URL(fileURLWithPath: "/tmp/scratch/dmg.x"), devices: []))
        XCTAssertTrue(gone)
        XCTAssertEqual(script.detaches, [["detach", "-force", "/tmp/scratch/dmg.x"]])
    }

    func testAnImageThatWillNotDetachAfterAFailedAttachIsStillAttached() async throws {
        let script = Script([ok(plist(mounts: [])), failed(), failed(), failed()])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? UpdateImageError, .stillAttached)
        }
        XCTAssertEqual(script.detaches.count, 3)
    }

    func testTheDetachRunsEvenInACancelledTask() async throws {
        let script = Script([ok()])
        let disk = disk(script)
        let mount = UpdateMount(mountPoint: scratch, devices: ["/dev/disk9"])
        let task = Task { () -> Bool in
            try? await Task.sleep(for: .milliseconds(50))
            return await disk.detach(mount)
        }
        task.cancel()
        let gone = await task.value
        XCTAssertTrue(gone)
    }

    /// Cleanup after a failure must not outlast the ceiling by minutes: the
    /// lookup and every detach try have a short timeout of their own.
    func testCleanupCallsAreShort() async throws {
        let script = Script([timedOut(), ok(info(device: "/dev/disk7", imagePath: "/tmp/scratch/Isla.dmg")), failed(), failed(), ok()])
        do { _ = try await disk(script).attach(image, scratch: scratch); XCTFail() } catch {}
        XCTAssertEqual(script.calls.map { $0.arguments.first }, ["attach", "info", "detach", "detach", "detach"])
        XCTAssertEqual(script.timeouts.dropFirst().max(), 10, "info and each detach try: 10 s")
    }

    func testCleanUpDetachesAnImageThatMountedLate() async throws {
        let script = Script([ok(info(device: "/dev/disk7", imagePath: "/tmp/scratch/Isla.dmg")), ok()])
        let clean = await disk(script).cleanUp(image: image)
        XCTAssertTrue(clean)
        XCTAssertEqual(script.detaches, [["detach", "-force", "/dev/disk7"]])
    }

    func testCleanUpWithNothingAttachedDetachesNothing() async throws {
        let script = Script([ok(info(device: "/dev/disk7", imagePath: "/tmp/elsewhere.dmg"))])
        let clean = await disk(script).cleanUp(image: image)
        XCTAssertTrue(clean)
        XCTAssertEqual(script.detaches, [])
    }

    func testCleanUpSaysSoWhenItCannotLetGo() async throws {
        let script = Script([ok(info(device: "/dev/disk7", imagePath: "/tmp/scratch/Isla.dmg")), failed(), failed(), failed()])
        let clean = await disk(script).cleanUp(image: image)
        XCTAssertFalse(clean)
        XCTAssertEqual(script.detaches.count, 3)
    }
}
