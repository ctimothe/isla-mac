// The release side of Isla's in-app update: makes the Ed25519 key pair, signs a
// disk image, and checks a signature, with CryptoKit and nothing else.
//
//   swift Scripts/update-signing.swift create-key <public-key-file>
//       makes a key pair, stores the private half in the login keychain
//       (service "Isla Update Signing", account "ed25519") and writes the
//       public half to <public-key-file>; refuses if the keychain has one
//   swift Scripts/update-signing.swift sign <file>
//       signs with the keychain's key (macOS may ask to allow the read) and
//       prints the signature as one base64 line
//   swift Scripts/update-signing.swift sign --stdin <file>  < private-key-base64
//   swift Scripts/update-signing.swift generate
//       for tests: prints "private <base64>" and "public <base64>"
//   swift Scripts/update-signing.swift verify <public-key-file> <file> <signature-file>
//       exits 0 when the signature is valid, 1 when it is not
//
// The private key never appears on a command line, where `ps` would show it to
// every process on the Mac: it goes from CryptoKit into the keychain inside this
// process, and comes back out the same way (or on stdin, for tests). The app checks the same signature
// with the same algorithm (`UpdateSignature` in IslaKit), so a disk image this
// script signs is the only kind Update Now will install.
import CryptoKit
import Foundation
import Security

let service = "Isla Update Signing"
let account = "ed25519"

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("update-signing: \(message)\n".utf8))
    exit(code)
}

func readKey(_ text: String, what: String) -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
        fail("the \(what) key is not 32 bytes of base64")
    }
    return data
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

/// The stored private key, as its base64 text, or nil when there is none. The
/// read can raise macOS's "allow access" prompt; that is the point.
func keychainKey() -> String? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecReturnData: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(decoding: data, as: UTF8.self)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    print("private \(key.rawRepresentation.base64EncodedString())")
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")

case "create-key":
    guard arguments.count == 2 else { fail("usage: create-key <public-key-file>") }
    if keychainKey() != nil { fail("the login keychain already holds an update signing key") }
    let key = Curve25519.Signing.PrivateKey()
    let item: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: account,
        kSecAttrLabel: service,
        kSecAttrDescription: "Ed25519 private key",
        kSecValueData: Data(key.rawRepresentation.base64EncodedString().utf8),
    ]
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { fail("could not store the key in the login keychain (\(status))") }
    let publicLine = key.publicKey.rawRepresentation.base64EncodedString() + "\n"
    guard FileManager.default.createFile(atPath: arguments[1], contents: Data(publicLine.utf8)) else {
        fail("stored the private key but could not write \(arguments[1])")
    }
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")

case "sign":
    let fromStdin = arguments.count == 3 && arguments[1] == "--stdin"
    guard arguments.count == 2 || fromStdin else { fail("usage: sign [--stdin] <file>") }
    let keyText: String
    if fromStdin {
        keyText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        guard let stored = keychainKey() else {
            fail("no update signing key in the login keychain; run Scripts/make-update-key.sh")
        }
        keyText = stored
    }
    let raw = readKey(keyText, what: "private")
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("the private key is not a valid Ed25519 key")
    }
    let file = readFile(arguments[arguments.count - 1])
    guard let signature = try? key.signature(for: file) else { fail("signing failed") }
    // Checked before it is printed: a signature the public half rejects would
    // reach users as an update that refuses to install.
    guard key.publicKey.isValidSignature(signature, for: file) else { fail("the new signature does not verify") }
    print(signature.base64EncodedString())

case "verify":
    guard arguments.count == 4 else { fail("usage: verify <public-key-file> <file> <signature-file>") }
    let raw = readKey(String(decoding: readFile(arguments[1]), as: UTF8.self), what: "public")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("the public key is not a valid Ed25519 key")
    }
    let signatureText = String(decoding: readFile(arguments[3]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
        fail("the signature is not 64 bytes of base64", code: 1)
    }
    guard key.isValidSignature(signature, for: readFile(arguments[2])) else {
        fail("the signature does not match", code: 1)
    }
    print("signature ok")

default:
    fail("usage: update-signing.swift generate | sign <file> | verify <public-key-file> <file> <signature-file>")
}
