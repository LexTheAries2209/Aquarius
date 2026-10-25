// SPDX-License-Identifier: GPL-3.0-only
// Compiled only by script/test_sparkle_update.py, never into Aquarius.

import AppKit
import Sparkle

@main
struct SparkleUpdateFixture {
    static func main() {
        let application = NSApplication.shared
        let delegate = FixtureDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
private final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var updater: AppUpdater?
    private var root: URL?
    private var scenario = ""
    private var checkTimer: Timer?
    private var isBusy = false
    private var blockedAt: TimeInterval?
    private var didStartUpdateCheck = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let rootPath = Bundle.main.object(forInfoDictionaryKey: "AquariusFixtureRoot") as? String,
              let scenario = Bundle.main.object(forInfoDictionaryKey: "AquariusFixtureScenario") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            finish(["result": "fixture-error", "detail": "Fixture metadata is missing."])
            return
        }

        root = URL(fileURLWithPath: rootPath, isDirectory: true)
        self.scenario = scenario
        if build == "0002" {
            finish([
                "result": "updated",
                "build": build,
                "preferencesRetained": UserDefaults.standard.string(forKey: "fixture.marker") == "before-update",
                "historyRetained": FileManager.default.fileExists(atPath: root!.appendingPathComponent("history.marker").path)
            ])
            return
        }

        UserDefaults.standard.set("before-update", forKey: "fixture.marker")
        try? Data("history".utf8).write(to: root!.appendingPathComponent("history.marker"), options: .atomic)

        let safety = AppUpdateSafetyGate(isBusy: { [weak self] in self?.isBusy ?? false })
        let owner = AppUpdater(
            safety: safety,
            hostBundle: .main,
            defaults: .standard,
            standardUserDriverFactory: { [weak self] owner in
                FixtureUserDriver(
                    owner: owner,
                    scenario: self?.scenario ?? "update",
                    onError: { [weak self] error in
                        self?.finish([
                            "result": "failed",
                            "detail": error,
                            "installationReserved": owner.safety.isReserved
                        ])
                    },
                    onDownload: { [weak self] in
                        guard self?.scenario == "download-conflict" else { return }
                        self?.isBusy = true
                        owner.conflictsDidChange()
                    },
                    onExtraction: { [weak self] in
                        guard self?.scenario == "ready-conflict" else { return }
                        self?.isBusy = true
                        owner.conflictsDidChange()
                    }
                )
            }
        )
        updater = owner
        owner.start()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak owner] timer in
            MainActor.assumeIsolated {
                guard let self, let owner else {
                    timer.invalidate()
                    return
                }
                if ["download-conflict", "ready-conflict"].contains(self.scenario),
                   case .blocked(let message) = owner.state {
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.blockedAt == nil { self.blockedAt = now }
                    guard now - self.blockedAt! >= 1.5 else { return }
                    timer.invalidate()
                    self.checkTimer = nil
                    self.finish([
                        "result": "blocked",
                        "detail": message,
                        "build": build,
                        "preparedInstallation": owner.hasPendingInstallation,
                        "installationReserved": owner.safety.isReserved
                    ])
                } else if ["download-conflict", "ready-conflict"].contains(self.scenario) {
                    guard !self.didStartUpdateCheck, owner.canCheckForUpdates else { return }
                    self.didStartUpdateCheck = true
                    owner.checkNow()
                } else if owner.canCheckForUpdates {
                    timer.invalidate()
                    self.checkTimer = nil
                    owner.checkNow()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.finish(["result": "timeout", "state": "\(owner.state)"])
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater?.applicationMayTerminate() == false ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard scenario == "cancel-install" || scenario == "quit-before-ready",
              let root,
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) else { return }
        finish([
            "result": "cancelled",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "preparedInstallation": updater?.hasPendingInstallation ?? false,
            "installationReserved": updater?.safety.isReserved ?? false
        ])
    }

    private func finish(_ result: [String: Any]) {
        guard let root else {
            NSApp.terminate(nil)
            return
        }
        let resultURL = root.appendingPathComponent("result.json")
        guard !FileManager.default.fileExists(atPath: resultURL.path) else { return }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: resultURL, options: .atomic)
        }
        checkTimer?.invalidate()
        checkTimer = nil
        NSApp.terminate(nil)
    }
}

@MainActor
private final class FixtureUserDriver: NSObject, SPUUserDriver {
    private weak var owner: AppUpdater?
    private let scenario: String
    private let onError: (String) -> Void
    private let onDownload: () -> Void
    private let onExtraction: () -> Void

    init(
        owner: AppUpdater,
        scenario: String,
        onError: @escaping (String) -> Void,
        onDownload: @escaping () -> Void,
        onExtraction: @escaping () -> Void
    ) {
        self.owner = owner
        self.scenario = scenario
        self.onError = onError
        self.onDownload = onDownload
        self.onExtraction = onExtraction
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.recordCheckResult(error)
        onError("No update: \(error.localizedDescription)")
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner?.recordUpdaterError(error)
        onError(error.localizedDescription)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { onDownload() }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { onExtraction() }
    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if scenario == "quit-before-ready" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } else if scenario == "cancel-install" {
            reply(.skip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } else {
            reply(.install)
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
}
