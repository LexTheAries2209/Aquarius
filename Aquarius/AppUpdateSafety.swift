// SPDX-License-Identifier: GPL-3.0-only

import Foundation

struct AppUpdateBlockedError: Error, Equatable {
    let message: String
}

@MainActor
final class AppUpdateSafetyGate {
    private let isBusy: () -> Bool
    private let reserve: () -> Void
    private let release: () -> Void
    private(set) var isReserved = false

    init(
        isBusy: @escaping () -> Bool,
        reserve: @escaping () -> Void = {},
        release: @escaping () -> Void = {}
    ) {
        self.isBusy = isBusy
        self.reserve = reserve
        self.release = release
    }

    func check() throws {
        guard !isBusy() else {
            throw AppUpdateBlockedError(message: "请先完成当前识别或文件处理任务，再安装更新。")
        }
    }

    func beginInstallation() throws {
        try check()
        guard !isReserved else { return }
        isReserved = true
        reserve()
    }

    func endInstallation() {
        guard isReserved else { return }
        isReserved = false
        release()
    }
}
