// SPDX-License-Identifier: GPL-3.0-only
// Read-only probe for staged or published Aquarius appcasts.

import AppKit
import Sparkle

@main
struct SparkleFeedProbe {
    static func main() {
        let application = NSApplication.shared
        let delegate = FeedProbeDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class FeedProbeDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var result: [String: String] = [:]
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            self.updater = updater
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            try updater.start()
            updater.checkForUpdateInformation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 35) { [weak self] in
                self?.finish(["result": "timeout"])
            }
        } catch {
            finish(["result": "error", "detail": error.localizedDescription])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        result = [
            "result": "available",
            "build": item.versionString,
            "version": item.displayVersionString,
            "downloadURL": item.fileURL?.absoluteString ?? ""
        ]
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let nsError = error as NSError
        result = [
            "result": nsError.domain == SUSparkleErrorDomain
                && nsError.code == Int(SUError.noUpdateError.rawValue) ? "upToDate" : "error",
            "detail": error.localizedDescription
        ]
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if !result.isEmpty {
            finish(result)
        } else {
            finish(["result": "error", "detail": error?.localizedDescription ?? "No feed result"])
        }
    }

    private func finish(_ result: [String: String]) {
        guard !finished else { return }
        finished = true
        let path = Bundle.main.object(forInfoDictionaryKey: "AquariusProbeOutputPath") as! String
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NSApp.terminate(nil)
    }
}
