// SPDX-License-Identifier: GPL-3.0-only

//
//  AquariusApp.swift
//  Aquarius
//
//  Created by 吴坤城 on 7/3/26.
//

import SwiftUI

@main
struct AquariusApp: App {
    @NSApplicationDelegateAdaptor(AquariusAppDelegate.self) private var appDelegate
    @StateObject private var viewModel: AnalysisViewModel
    @StateObject private var updater: AppUpdater

    init() {
        let viewModel = AnalysisViewModel()
        _viewModel = StateObject(wrappedValue: viewModel)
        _updater = StateObject(wrappedValue: AppUpdater(
            safety: AppUpdateSafetyGate(
                isBusy: { viewModel.hasActiveMediaOperation },
                reserve: { viewModel.setAppUpdateReserved(true) },
                release: { viewModel.setAppUpdateReserved(false) }
            )
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .disabled(viewModel.isAppUpdateReserved)
                .onChange(of: viewModel.isAnalyzing) {
                    updater.conflictsDidChange()
                }
                .task {
                    appDelegate.updater = updater
                    updater.applicationDidLaunch()
                }
        }
        .defaultSize(width: 1433, height: 732)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button {
                    updater.checkNow()
                } label: {
                    if case .available(let version) = updater.state {
                        Label("有更新：\(version)", systemImage: "arrow.down.circle.fill")
                    } else {
                        Text("检查更新…")
                    }
                }
                .disabled(updater.isInstallationReserved || (updater.isStarted && !updater.canCheckForUpdates))

                SettingsLink()
            }
        }

        Settings {
            ProjectSettingsView(viewModel: viewModel, updater: updater)
        }
        .defaultSize(width: 620, height: 680)
        .windowResizability(.contentSize)
    }
}
