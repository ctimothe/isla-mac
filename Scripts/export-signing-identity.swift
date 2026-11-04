// Writes Isla's own signing identity, the one Scripts/signing-identity.sha1
// pins, out of the keychain as a .p12, so setup-release-secrets.sh can hand it
// to the release job without anyone typing a passphrase.
//
//   ISLA_EXPORT_PASS=<passphrase> swift Scripts/export-signing-identity.swift <sha1> <out.p12> [keychain]
//
// Why it exists: the release job needs the certificate and its private key as
// a .p12, and that file's passphrase. The backup make-signing-identity.sh
// writes is locked with a passphrase the owner typed once; on 2026-11-04
// nobody had it any more, and the first CI release stopped at that prompt. The
// identity itself is in the login keychain, so a fresh export under a random
// passphrase carries the same certificate and the same key: every installed
// copy goes on trusting updates signed with it, and nobody has to remember
// anything.
//
// Only the pinned identity leaves the keychain. `security export -t
// identities` would take every identity there is and hand GitHub keys that
// have nothing to do with Isla. The passphrase comes from the environment,
// never from a command line `ps` shows. macOS asks once whether the key may be
// exported; that dialog is the owner's consent, and nothing here answers it.
//
// The optional keychain path is for a rehearsal in a throwaway keychain. A real
// run searches the keychain list, as codesign does.
import CryptoKit
import Foundation
import Security

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("export-signing-identity: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 || arguments.count == 3 else {
    fail("usage: ISLA_EXPORT_PASS=<passphrase> swift Scripts/export-signing-identity.swift <sha1> <out.p12> [keychain]")
}
let pin = arguments[0].uppercased()
let output = URL(fileURLWithPath: arguments[1])
guard let passphrase = ProcessInfo.processInfo.environment["ISLA_EXPORT_PASS"], passphrase.count >= 12 else {
    fail("ISLA_EXPORT_PASS must hold the passphrase, at least 12 characters")
}

var query: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
]
if arguments.count == 3 {
    var keychain: SecKeychain?
    guard SecKeychainOpen(arguments[2], &keychain) == errSecSuccess, let keychain else {
        fail("cannot open the keychain at \(arguments[2])")
    }
    query[kSecMatchSearchList] = [keychain]
}

var found: CFTypeRef?
let searched = SecItemCopyMatching(query as CFDictionary, &found)
guard searched == errSecSuccess, let identities = found as? [SecIdentity] else {
    fail("the keychain has no signing identity at all (OSStatus \(searched))")
}

// The SHA-1 `security find-identity` prints and the pin file holds: of the
// certificate's DER bytes.
func fingerprint(of identity: SecIdentity) -> String? {
    var certificate: SecCertificate?
    guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
    let der = SecCertificateCopyData(certificate) as Data
    return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
}

// The same identity can come back once per keychain that holds it; any of them
// is the same certificate and key.
guard let identity = identities.first(where: { fingerprint(of: $0) == pin }) else {
    fail("no identity in the keychain has the pinned certificate \(pin); restore it from its backup with Scripts/make-signing-identity.sh's instructions")
}

let secret = passphrase as CFString
var parameters = SecItemImportExportKeyParameters(
    version: UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION),
    flags: [],
    passphrase: Unmanaged.passUnretained(secret as CFTypeRef),
    alertTitle: nil,
    alertPrompt: nil,
    accessRef: nil,
    keyUsage: nil,
    keyAttributes: nil)
var exported: CFData?
let status = withExtendedLifetime(secret) {
    SecItemExport(identity, .formatPKCS12, [], &parameters, &exported)
}
guard status == errSecSuccess, let exported else {
    fail("macOS did not export the key (OSStatus \(status)); run it again and click Allow when macOS asks")
}

// Readable by the owner alone, like the backup make-signing-identity.sh writes.
guard FileManager.default.createFile(
    atPath: output.path, contents: exported as Data, attributes: [.posixPermissions: 0o600])
else {
    fail("cannot write \(output.path)")
}
