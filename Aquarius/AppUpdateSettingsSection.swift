// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct AppUpdateSettingsSection: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("更新") {
            LabeledContent("当前版本", value: updater.currentVersion)

            Toggle("启动时检查更新", isOn: Binding(
                get: { updater.checksOnLaunch },
                set: { updater.setChecksOnLaunch($0) }
            ))

            HStack(spacing: 10) {
                Button {
                    updater.checkNow()
                } label: {
                    Label("检查更新…", systemImage: "arrow.clockwise")
                }
                .disabled(updater.isInstallationReserved || (updater.isStarted && !updater.canCheckForUpdates))
                .fixedSize()

                if let lastCheckedAt = updater.lastCheckedAt {
                    Text("上次检查：\(lastCheckedAt.formatted(.dateTime.year().month(.twoDigits).day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button("打开 Releases") {
                    openURL(AppUpdateConfiguration.releasesURL)
                }
                .fixedSize()
            }

            statusContent

        }
        .onAppear {
            updater.start()
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch updater.state {
        case .idle:
            Text("尚未检查更新。")
                .foregroundStyle(.secondary)
        case .checking:
            Label("正在检查更新…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .upToDate:
            Label("已是最新版本。", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .available(let version):
            Label("发现新版本：\(version)", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading:
            ProgressView("正在下载更新…")
        case .extracting:
            Label("正在验证并准备更新…", systemImage: "shippingbox")
                .foregroundStyle(.secondary)
        case .readyToInstall:
            Label("更新已准备就绪，等待安装确认。", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .installing:
            Label("正在安装更新…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .blocked(let message):
            Label(message, systemImage: "hand.raised")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
