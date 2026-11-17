// Verifies an EdDSA (ed25519) signature of a file against a public key, as
// Sparkle does before it installs an update (docs/DESIGN.md section 11,
// "Release pipeline"). Used by scripts/release.sh and scripts/appcast.sh;
// it reads no key from anywhere but its arguments, and needs no private key.
//
//   /usr/bin/swift scripts/ed25519-verify.swift <public key, base64> <signature, base64> <file>
//
// Exits 0 when the signature verifies, 1 when it does not, 2 on bad input.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: ed25519-verify.swift <public key> <signature> <file>\n".utf8))
    exit(2)
}
let values = Array(arguments)
guard let keyData = Data(base64Encoded: values[0].trimmingCharacters(in: .whitespacesAndNewlines)), keyData.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("ed25519-verify: the public key is not 32 bytes of base64\n".utf8))
    exit(2)
}
guard let signature = Data(base64Encoded: values[1].trimmingCharacters(in: .whitespacesAndNewlines)),
      signature.count == 64
else {
    FileHandle.standardError.write(Data("ed25519-verify: the signature is not 64 bytes of base64\n".utf8))
    exit(2)
}
guard let data = try? Data(contentsOf: URL(fileURLWithPath: values[2]), options: .mappedIfSafe) else {
    FileHandle.standardError.write(Data("ed25519-verify: cannot read \(values[2])\n".utf8))
    exit(2)
}
if key.isValidSignature(signature, for: data) {
    print("ed25519-verify: the signature of \(values[2]) (\(data.count) bytes) verifies")
    exit(0)
}
FileHandle.standardError.write(Data("ed25519-verify: the signature of \(values[2]) does NOT verify\n".utf8))
exit(1)
