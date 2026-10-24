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
    @StateObject private var viewModel = AnalysisViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(width: 1433, height: 732)

        Settings {
            ProjectSettingsView(viewModel: viewModel)
        }
        .defaultSize(width: 620, height: 680)
        .windowResizability(.contentSize)
    }
}
