import CryptoKit
import Foundation

/// Whether a downloaded disk image is the one Isla's release script signed.
///
/// Update Now has no Apple identity to check a download against, so the
/// release carries an Ed25519 signature of its own over the whole `.dmg` file
/// (`Scripts/update-signing.swift`, one base64 line beside the image) and the
/// public half of the key is in the app's Info.plist as `IslaUpdatePublicKey`.
/// This is the gate: a disk image is mounted only after it passes, because
/// mounting is attack surface, and what is checked here is the bytes on disk
/// that will be mounted, not an earlier stream of them.
///
/// Everything it is given comes from outside — the file, the signature, the
/// key — so any malformed input is "not valid", never a crash.
enum UpdateSignature {
    /// The public key this build trusts, as base64 of its 32 raw bytes, or nil
    /// for a build made without one (`Resources/update-public-key.txt`).
    nonisolated static var bundledPublicKey: String? {
        Bundle.main.infoDictionary?["IslaUpdatePublicKey"] as? String
    }

    /// Whether `key` is the base64 of 32 bytes, which is all an Ed25519 public
    /// key is. A build whose key is anything else cannot verify an update and
    /// so does not offer to install one.
    nonisolated static func isUsablePublicKey(_ key: String?) -> Bool {
        guard let key, let data = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return data.count == 32 && (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil
    }

    /// Whether `signatureBase64` (64 bytes, as the script prints it) is a valid
    /// signature of the file at `fileURL` by `publicKeyBase64`.
    ///
    /// The file is read into memory, not mapped. A mapped file that is truncated
    /// while it is being read raises SIGBUS, which no `catch` can answer and
    /// which would take Isla down; a read of a file that changes simply gets
    /// different bytes, and the check fails. The image is capped at 100 MB
    /// (`UpdateCheck.AssetKind.sizeLimit`), so the copy in memory is bounded;
    /// today's is under five.
    nonisolated static func isValid(signatureBase64: String, publicKeyBase64: String, fileURL: URL) -> Bool {
        guard signatureBase64.utf8.count < 1024,
              let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64,
              let keyBytes = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyBytes.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let isDirectory = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, !isDirectory,
              let file = try? Data(contentsOf: fileURL)
        else { return false }
        return key.isValidSignature(signature, for: file)
    }
}
