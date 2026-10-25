// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Combine
import Sparkle

enum AppUpdaterState: Equatable {
    case idle
    case checking
    case upToDate
    case available(String)
    case downloading
    case extracting
    case readyToInstall
    case installing
    case blocked(String)
    case failed(String)
}

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, ObservableObject {
    enum PreferenceKey {
        static let checksOnLaunch = "aquarius.checksForUpdatesOnLaunch"
        static let lastCheck = "SULastCheckTime"
    }

    @Published private(set) var state: AppUpdaterState = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checksOnLaunch: Bool
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var isStarted = false
    @Published private(set) var hasPendingInstallation = false
    @Published private(set) var isInstallationReserved = false

    let safety: AppUpdateSafetyGate
    private let defaults: UserDefaults
    private let hostBundle: Bundle
    private let standardUserDriverFactory: (@MainActor (AppUpdater) -> SPUUserDriver)?
    private var updater: SPUUpdater?
    private var userDriver: SPUUserDriver?
    private var observations: [NSKeyValueObservation] = []
    private var hasAttemptedStart = false
    private var hasHandledApplicationLaunch = false
    private var launchCheckTimeout: Task<Void, Never>?
    private var postponedRelaunch: (() -> Void)?
    private var cancelPreparedInstallation: (() -> Void)?
    private var quitsAfterCancellingUpdate = false
    private var isCancellingPreparedInstallation = false

    init(
        safety: AppUpdateSafetyGate,
        hostBundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        standardUserDriverFactory: (@MainActor (AppUpdater) -> SPUUserDriver)? = nil
    ) {
        self.safety = safety
        self.hostBundle = hostBundle
        self.defaults = defaults
        self.standardUserDriverFactory = standardUserDriverFactory
        checksOnLaunch = defaults.object(forKey: PreferenceKey.checksOnLaunch) as? Bool ?? false
        lastCheckedAt = defaults.object(forKey: PreferenceKey.lastCheck) as? Date
        super.init()
    }

    var currentVersion: String {
        hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? hostBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Aquarius"
    }

    func start() {
        guard !hasAttemptedStart else { return }
        hasAttemptedStart = true

        do {
            _ = try AppUpdateConfiguration(
                info: hostBundle.infoDictionary ?? [:],
                allowsLocalTestFeed: hostBundle.bundleIdentifier == "lex.Aquarius.UpdateFixture"
                    || hostBundle.bundleIdentifier?.hasPrefix("lex.Aquarius.UpdateFixture.") == true
            )

            // Fixture drivers replace only Sparkle's presentation layer; the guarded policy remains active.
            let standard = standardUserDriverFactory?(self)
                ?? SPUStandardUserDriver(hostBundle: hostBundle, delegate: self)
            let driver = GuardedUpdateUserDriver(standard: standard, owner: self)
            let updater = SPUUpdater(
                hostBundle: hostBundle,
                applicationBundle: hostBundle,
                userDriver: driver,
                delegate: self
            )
            self.userDriver = driver
            self.updater = updater

            // Launch checks are scheduled by Aquarius so Sparkle never prompts or downloads on its own.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            try updater.start()
            isStarted = true
            synchronizeSettings()
            observations = [
                updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.synchronizeSettings() }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.synchronizeSettings() }
                }
            ]
        } catch {
            state = .failed("更新组件配置无效：\(error.localizedDescription)")
        }
    }

    func applicationDidLaunch() {
        guard !hasHandledApplicationLaunch else { return }
        hasHandledApplicationLaunch = true
        guard !Self.isRunningUnderXCTest else { return }
        start()
        guard checksOnLaunch, let updater, isStarted, updater.canCheckForUpdates else { return }
        transition(to: .checking)
        launchCheckTimeout?.cancel()
        launchCheckTimeout = Task { @MainActor [weak self, weak updater] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, let updater, !Task.isCancelled,
                  self.updater === updater,
                  case .checking = self.state else { return }
            self.expireLaunchCheck(updater)
        }
        updater.checkForUpdatesInBackground()
    }

    func checkNow() {
        guard !safety.isReserved else { return }
        if let resume = postponedRelaunch {
            guard authorizeUpdate(installing: true) else { return }
            postponedRelaunch = nil
            resume()
            return
        }

        start()
        guard let updater, isStarted else {
            if case .failed = state { return }
            state = .failed("更新组件尚未启动。")
            return
        }
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func setChecksOnLaunch(_ enabled: Bool) {
        defaults.set(enabled, forKey: PreferenceKey.checksOnLaunch)
        checksOnLaunch = enabled
    }

    func transition(to newState: AppUpdaterState) {
        if newState != .checking {
            launchCheckTimeout?.cancel()
            launchCheckTimeout = nil
        }
        state = newState
    }

    func recordCheckResult(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain,
           nsError.code == Int(SUError.noUpdateError.rawValue) {
            transition(to: .upToDate)
        } else {
            transition(to: .failed(Self.userFacingMessage(for: nsError)))
        }
    }

    func recordUpdaterError(_ error: Error) {
        let nsError = error as NSError
        markPendingInstallation(false)
        if case .blocked = state { return }
        transition(to: .failed(Self.userFacingMessage(for: nsError)))
    }

    func authorizeUpdate(installing: Bool = false) -> Bool {
        do {
            if installing {
                try safety.beginInstallation()
                isInstallationReserved = true
            } else {
                try safety.check()
            }
            return true
        } catch let blocked as AppUpdateBlockedError {
            state = .blocked(blocked.message)
            return false
        } catch {
            state = .blocked("当前无法安全安装更新。")
            return false
        }
    }

    func markPendingInstallation(_ pending: Bool) {
        hasPendingInstallation = pending
        if !pending {
            clearPreparedInstallationCancellation()
            postponedRelaunch = nil
            safety.endInstallation()
            isInstallationReserved = false
        }
    }

    func conflictsDidChange() {
        guard !safety.isReserved else { return }
        do {
            try safety.check()
            if case .blocked = state { state = .idle }
        } catch let blocked as AppUpdateBlockedError {
            guard let driver = userDriver as? GuardedUpdateUserDriver else { return }
            state = .blocked(blocked.message)
            driver.cancelActiveDownload()
            driver.cancelPreparedInstallation()
        } catch {
            state = .blocked("当前无法安全安装更新。")
        }
    }

    func registerPreparedInstallationCancellation(_ cancellation: @escaping () -> Void) -> Bool {
        if quitsAfterCancellingUpdate {
            cancellation()
            return false
        }
        cancelPreparedInstallation = cancellation
        return true
    }

    func clearPreparedInstallationCancellation() {
        cancelPreparedInstallation = nil
    }

    func didCancelPreparedInstallation() {
        markPendingInstallation(false)
        isCancellingPreparedInstallation = true
        if case .blocked = state { return }
        if case .failed = state { return }
        if case .available = state { return }
        state = .idle
    }

    func applicationMayTerminate() -> Bool {
        guard !quitsAfterCancellingUpdate else { return false }

        if (hasPendingInstallation && !safety.isReserved) || isCancellingPreparedInstallation {
            quitsAfterCancellingUpdate = true
            cancelPreparedInstallation?()
            return false
        }

        if isCancellingPreparedInstallation { return false }
        guard hasPendingInstallation || safety.isReserved else { return true }
        return authorizeUpdate(installing: true)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard self.updater === updater else {
            throw AppUpdateBlockedError(message: "更新检查已取消。")
        }
        transition(to: .checking)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard self.updater === updater else { return }
        transition(to: .available(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard self.updater === updater else { return }
        synchronizeSettings()
        recordCheckResult(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard self.updater === updater else { return }
        launchCheckTimeout?.cancel()
        launchCheckTimeout = nil
        defer {
            isCancellingPreparedInstallation = false
            if quitsAfterCancellingUpdate {
                quitsAfterCancellingUpdate = false
                markPendingInstallation(false)
                Task { @MainActor in NSApp.terminate(nil) }
            }
        }

        synchronizeSettings()
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain,
           [SUError.noUpdateError.rawValue, SUError.installationCanceledError.rawValue].contains(OSStatus(nsError.code)) {
            if nsError.code == Int(SUError.installationCanceledError.rawValue) {
                markPendingInstallation(false)
                if case .blocked = state { return }
                state = .idle
            }
            return
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.cancelled.rawValue {
            markPendingInstallation(false)
            if case .blocked = state { return }
            state = .idle
            return
        }
        markPendingInstallation(false)
        if case .blocked = state { return }
        state = .failed(Self.userFacingMessage(for: nsError))
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard self.updater === updater else { return true }
        guard authorizeUpdate(installing: true) else {
            postponedRelaunch = installHandler
            return true
        }
        return false
    }

    private func expireLaunchCheck(_ updater: SPUUpdater) {
        guard self.updater === updater else { return }
        (userDriver as? GuardedUpdateUserDriver)?.cancelActiveCheck()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        (userDriver as? GuardedUpdateUserDriver)?.invalidate()
        userDriver = nil
        self.updater = nil
        isStarted = false
        hasAttemptedStart = false
        canCheckForUpdates = true
        let checkedAt = Date()
        lastCheckedAt = checkedAt
        defaults.set(checkedAt, forKey: PreferenceKey.lastCheck)
        launchCheckTimeout = nil
        if case .blocked = state { return }
        state = .failed("检查更新超时，请稍后手动重试。")
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }

    var supportsGentleScheduledUpdateReminders: Bool { false }

    private func synchronizeSettings() {
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        if let date = updater.lastUpdateCheckDate {
            lastCheckedAt = date
            defaults.set(date, forKey: PreferenceKey.lastCheck)
        }
    }

    private static func userFacingMessage(for error: NSError, depth: Int = 0) -> String {
        guard depth < 8 else { return "更新失败，请稍后重试。" }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        let multipleUnderlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? []
        if ([underlying].compactMap { $0 } + multipleUnderlying).contains(where: isSignatureError) {
            return "更新签名验证失败，已阻止安装。"
        }
        if error.domain == NSURLErrorDomain {
            return "无法连接更新服务器，请检查网络连接后重试。"
        }
        if error.domain == SUSparkleErrorDomain {
            switch SUError(rawValue: OSStatus(error.code)) {
            case .signatureError, .validationError, .insufficientSigningError:
                return "更新签名验证失败，已阻止安装。"
            case .appcastError, .appcastParseError, .resumeAppcastError:
                return "更新清单无效或暂不可用。"
            default:
                break
            }
        }
        if let underlying {
            return userFacingMessage(for: underlying, depth: depth + 1)
        }
        if let nested = multipleUnderlying.first {
            return userFacingMessage(for: nested, depth: depth + 1)
        }
        return "更新失败：\(error.localizedDescription)"
    }

    private static func isSignatureError(_ error: NSError) -> Bool {
        guard error.domain == SUSparkleErrorDomain else { return false }
        switch SUError(rawValue: OSStatus(error.code)) {
        case .signatureError, .validationError, .insufficientSigningError:
            return true
        default:
            return false
        }
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}
