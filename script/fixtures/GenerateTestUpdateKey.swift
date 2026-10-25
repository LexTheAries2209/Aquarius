// SPDX-License-Identifier: GPL-3.0-only

import CryptoKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: GenerateTestUpdateKey.swift PRIVATE_KEY_PATH")
}

let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let encodedKey = Data(key.rawRepresentation.base64EncodedString().utf8)
guard FileManager.default.createFile(
    atPath: keyURL.path,
    contents: encodedKey,
    attributes: [.posixPermissions: 0o600]
) else {
    fatalError("Unable to create the fixture key.")
}
print(key.publicKey.rawRepresentation.base64EncodedString())
