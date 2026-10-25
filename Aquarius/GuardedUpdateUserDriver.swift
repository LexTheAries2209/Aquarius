// SPDX-License-Identifier: GPL-3.0-only

import Sparkle

@MainActor
final class GuardedUpdateUserDriver: NSObject, SPUUserDriver {
    private let standard: SPUUserDriver
    private weak var owner: AppUpdater?
    private var cancelCheck: (() -> Void)?
    private var cancelDownload: (() -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var isInvalidated = false

    init(standard: SPUUserDriver, owner: AppUpdater) {
        self.standard = standard
        self.owner = owner
    }

    func invalidate() {
        isInvalidated = true
        cancelCheck = nil
        cancelDownload = nil
        owner = nil
    }

    func cancelActiveCheck() {
        let cancellation = cancelCheck
        cancelCheck = nil
        cancellation?()
    }

    func cancelActiveDownload() {
        let cancellation = cancelDownload
        cancelDownload = nil
        cancellation?()
    }

    func cancelPreparedInstallation() {
        guard readyReply != nil else { return }
        respondToReady(.skip)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request) { response in
            reply(SUUpdatePermissionResponse(
                automaticUpdateChecks: false,
                automaticUpdateDownloading: NSNumber(value: false),
                sendSystemProfile: false
            ))
        }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard !isInvalidated else { cancellation(); return }
        cancelCheck = cancellation
        owner?.transition(to: .checking)
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        guard !isInvalidated else { reply(.dismiss); return }
        owner?.transition(to: .available(appcastItem.displayVersionString))
        if state.stage == .installing {
            owner?.didCancelPreparedInstallation()
            reply(.skip)
            return
        }

        standard.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            guard let self else { reply(.dismiss); return }
            if choice == .install, self.owner?.authorizeUpdate() != true {
                reply(.dismiss)
            } else {
                reply(choice)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standard.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standard.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        guard !isInvalidated else { acknowledgement(); return }
        owner?.recordCheckResult(error)
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelCheck = nil
        owner?.recordUpdaterError(error)
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard owner?.authorizeUpdate() == true else {
            cancellation()
            return
        }
        expectedLength = 0
        receivedLength = 0
        cancelDownload = cancellation
        owner?.transition(to: .downloading)
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength = receivedLength.addingReportingOverflow(length).partialValue
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelDownload = nil
        owner?.markPendingInstallation(true)
        owner?.transition(to: .extracting)
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard owner?.authorizeUpdate() == true else {
            owner?.didCancelPreparedInstallation()
            reply(.skip)
            return
        }
        owner?.transition(to: .readyToInstall)
        readyReply = reply
        guard owner?.registerPreparedInstallationCancellation({ [weak self] in
            self?.respondToReady(.skip)
        }) == true else { return }
        standard.showReady(toInstallAndRelaunch: { [weak self] choice in
            self?.respondToReady(choice)
        })
    }

    private func respondToReady(_ choice: SPUUserUpdateChoice) {
        guard let reply = readyReply else { return }
        readyReply = nil
        owner?.clearPreparedInstallationCancellation()
        guard choice == .install, owner?.authorizeUpdate(installing: true) == true else {
            owner?.didCancelPreparedInstallation()
            reply(.skip)
            return
        }
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        owner?.transition(to: .installing)
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated) { [weak self] in
            guard self?.owner?.authorizeUpdate(installing: true) == true else { return }
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        owner?.markPendingInstallation(false)
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        cancelDownload = nil
        readyReply = nil
        owner?.clearPreparedInstallationCancellation()
        standard.dismissUpdateInstallation()
        if owner?.hasPendingInstallation == false {
            owner?.safety.endInstallation()
        }
    }

    func showUpdateInFocus() {
        standard.showUpdateInFocus?()
    }
}
