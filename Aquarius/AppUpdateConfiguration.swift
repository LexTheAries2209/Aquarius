// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct AppUpdateConfiguration {
    static let releasesURL = URL(string: "https://github.com/LexTheAries2209/Aquarius/releases")!

    let feedURL: URL
    let publicKey: String

    init(info: [String: Any], allowsLocalTestFeed: Bool = false) throws {
        guard let feedValue = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feedValue),
              let host = feedURL.host,
              feedURL.user == nil,
              feedURL.password == nil,
              feedURL.scheme == "https" || (
                allowsLocalTestFeed && feedURL.scheme == "http"
                    && ["127.0.0.1", "localhost"].contains(host)
              ),
              let publicKey = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: publicKey)?.count == 32,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true else {
            throw CocoaError(.coderInvalidValue)
        }

        self.feedURL = feedURL
        self.publicKey = publicKey
    }
}
