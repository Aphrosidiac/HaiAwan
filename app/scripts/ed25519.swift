// Ed25519 keys and signatures for Awan updates (the same scheme Sparkle 2 calls EdDSA):
// a signature is Ed25519 over the whole archive, base64-encoded; the public key is the raw
// 32-byte key, base64-encoded. Compiled and run by release-keys.sh / release.sh.
//
//   ed25519 generate <private.key>          write a new private key (0600) and print the public key
//   ed25519 public   <private.key>          print the public key
//   ed25519 sign     <private.key> <file>   print the file's signature
//   ed25519 verify   <public-b64> <file> <signature-b64>   exit 0 if valid
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func loadKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("can't read private key at \(path)") }
    return key
}

func readFile(_ path: String) -> Data {
    guard let d = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return d
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: ed25519 generate|public|sign|verify …") }

switch args[1] {
case "generate":
    let path = args[2]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) already exists — refusing to overwrite a release key") }
    let key = Curve25519.Signing.PrivateKey()
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard FileManager.default.createFile(atPath: path, contents: (key.rawRepresentation.base64EncodedString() + "\n").data(using: .utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("can't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count >= 4 else { fail("usage: ed25519 sign <private.key> <file>") }
    let sig = try! loadKey(args[2]).signature(for: readFile(args[3]))
    print(sig.base64EncodedString())
case "verify":
    guard args.count >= 5, let pub = Data(base64Encoded: args[2]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
          let sig = Data(base64Encoded: args[4]) else { fail("usage: ed25519 verify <public-b64> <file> <signature-b64>") }
    if key.isValidSignature(sig, for: readFile(args[3])) { print("valid") } else { fail("INVALID signature") }
default:
    fail("unknown command \(args[1])")
}
