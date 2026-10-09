import CryptoKit
import Foundation

// Independent verification against the public key embedded in the shipping app.
// No Keychain access and no signing key is needed by this verifier.
do {
    guard CommandLine.arguments.count == 4,
          let publicBytes = Data(base64Encoded: CommandLine.arguments[2]), publicBytes.count == 32,
          let signature = Data(base64Encoded: CommandLine.arguments[3]), signature.count == 64 else {
        throw NSError(domain: "ClipShelfRelease", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: bytes) else { throw NSError(domain: "ClipShelfRelease", code: 2) }
    print("Update archive signature verified against embedded public key")
} catch {
    FileHandle.standardError.write(Data("Update signature verification failed\n".utf8))
    exit(1)
}
