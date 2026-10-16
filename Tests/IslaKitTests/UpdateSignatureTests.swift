import CryptoKit
import Foundation
import XCTest
@testable import IslaKit

/// The one check that decides whether a downloaded disk image is Isla's. It
/// must agree with `Scripts/update-signing.swift` (Ed25519 over the whole file,
/// the signature one base64 line) and must never crash on anything it is given:
/// the file, the signature and the key all come from outside.
final class UpdateSignatureTests: XCTestCase {
    private func write(_ data: Data, _ folder: URL, _ name: String = "Isla.dmg") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testASignatureMadeByTheKeyVerifies() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data((0..<4096).map { UInt8($0 % 251) })
        let file = try write(image, folder)
        XCTAssertTrue(UpdateSignature.isValid(signatureBase64: key.sign(image), publicKeyBase64: key.publicBase64, fileURL: file))
    }

    /// The release script prints one line with a newline, and a hand-copied
    /// signature can carry spaces around it.
    func testSurroundingWhitespaceInTheSignatureIsIgnored() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data("image".utf8)
        let file = try write(image, folder)
        XCTAssertTrue(UpdateSignature.isValid(signatureBase64: " \(key.sign(image))\n", publicKeyBase64: key.publicBase64, fileURL: file))
        XCTAssertTrue(UpdateSignature.isValid(signatureBase64: key.sign(image), publicKeyBase64: key.publicBase64 + "\n", fileURL: file))
    }

    func testOneChangedByteFails() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        var image = Data((0..<4096).map { UInt8($0 % 251) })
        let signature = key.sign(image)
        image[2048] ^= 1
        let file = try write(image, folder)
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: signature, publicKeyBase64: key.publicBase64, fileURL: file))
    }

    func testAnAppendedByteFails() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data("image".utf8)
        let signature = key.sign(image)
        let file = try write(image + Data([0]), folder)
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: signature, publicKeyBase64: key.publicBase64, fileURL: file))
    }

    func testAnotherKeysSignatureFails() throws {
        let folder = try UpdateTestSupport.folder(self)
        let image = Data("image".utf8)
        let file = try write(image, folder)
        let signer = UpdateTestSupport.Key()
        let other = UpdateTestSupport.Key()
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: signer.sign(image), publicKeyBase64: other.publicBase64, fileURL: file))
    }

    func testMalformedSignaturesAreFalseAndNeverACrash() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data("image".utf8)
        let file = try write(image, folder)
        let good = key.sign(image)
        let bad: [(String, String)] = [
            ("empty", ""),
            ("not base64", "this is not base64!!"),
            ("truncated", String(good.dropLast(8))),
            ("half", String(good.prefix(good.count / 2))),
            ("one byte", Data([1]).base64EncodedString()),
            ("63 bytes", Data(repeating: 7, count: 63).base64EncodedString()),
            ("65 bytes", Data(repeating: 7, count: 65).base64EncodedString()),
            ("64 wrong bytes", Data(repeating: 7, count: 64).base64EncodedString()),
            ("a public key in its place", key.publicBase64),
            ("two lines", good + "\n" + good),
            ("huge", String(repeating: "A", count: 1_000_000)),
        ]
        for (label, signature) in bad {
            XCTAssertFalse(UpdateSignature.isValid(signatureBase64: signature, publicKeyBase64: key.publicBase64, fileURL: file), label)
        }
    }

    func testMalformedKeysAreFalseAndNeverACrash() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data("image".utf8)
        let file = try write(image, folder)
        let signature = key.sign(image)
        for (label, publicKey) in [
            ("empty", ""),
            ("not base64", "###"),
            ("31 bytes", Data(repeating: 1, count: 31).base64EncodedString()),
            ("33 bytes", Data(repeating: 1, count: 33).base64EncodedString()),
            ("the signature", signature),
        ] {
            XCTAssertFalse(UpdateSignature.isValid(signatureBase64: signature, publicKeyBase64: publicKey, fileURL: file), label)
        }
    }

    func testAnEmptyOrMissingFileFails() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let signedImage = Data("image".utf8)
        let empty = try write(Data(), folder, "empty.dmg")
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: key.sign(signedImage), publicKeyBase64: key.publicBase64, fileURL: empty))
        // An empty file is still a file: its own signature verifies, so the
        // size rule lives with the downloader, not here.
        XCTAssertTrue(UpdateSignature.isValid(signatureBase64: key.sign(Data()), publicKeyBase64: key.publicBase64, fileURL: empty))
        let missing = folder.appendingPathComponent("nope.dmg")
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: key.sign(signedImage), publicKeyBase64: key.publicBase64, fileURL: missing))
        XCTAssertFalse(UpdateSignature.isValid(signatureBase64: key.sign(signedImage), publicKeyBase64: key.publicBase64, fileURL: folder),
                       "a folder is not a file")
    }

    /// The same bytes the release script signs: its `generate` and `sign` are
    /// CryptoKit's `Curve25519.Signing` over the file, so a signature this
    /// test makes the same way is the one the script would print.
    func testAFileTheSizeOfARealImageVerifiesMapped() throws {
        let folder = try UpdateTestSupport.folder(self)
        let key = UpdateTestSupport.Key()
        let image = Data(repeating: 0xAB, count: 12 * 1024 * 1024)
        let file = try write(image, folder)
        XCTAssertTrue(UpdateSignature.isValid(signatureBase64: key.sign(image), publicKeyBase64: key.publicBase64, fileURL: file))
    }

    func testWhatMakesAPublicKeyUsable() {
        let key = UpdateTestSupport.Key()
        XCTAssertTrue(UpdateSignature.isUsablePublicKey(key.publicBase64))
        XCTAssertTrue(UpdateSignature.isUsablePublicKey(key.publicBase64 + "\n"))
        XCTAssertFalse(UpdateSignature.isUsablePublicKey(nil))
        XCTAssertFalse(UpdateSignature.isUsablePublicKey(""))
        XCTAssertFalse(UpdateSignature.isUsablePublicKey("abc"))
        XCTAssertFalse(UpdateSignature.isUsablePublicKey(Data(repeating: 1, count: 31).base64EncodedString()))
        XCTAssertFalse(UpdateSignature.isUsablePublicKey(Data(repeating: 1, count: 64).base64EncodedString()))
    }
}
