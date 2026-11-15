// Prints the public half of a Sparkle EdDSA private key.
//
//   swift eddsa-public-key.swift < private-key
//
// The private key is what `generate_keys -x` exports and what the
// SPARKLE_PRIVATE_KEY secret holds: the base64 of a 32-byte Ed25519 seed.
// The output is the string `generate_keys` prints for SUPublicEDKey, so
// generate-appcast.sh can check that the secret and
// scripts/sparkle-public-key.txt are one pair before anything is signed.
// The key is read from standard input and never printed.
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
else {
    FileHandle.standardError.write(Data("the private key is not the base64 of a 32-byte EdDSA seed (export it with generate_keys -x)\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
