// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation

@main
struct RunProjectSettingsSmoke {
    @MainActor
    static func main() throws {
        let decoder = JSONDecoder()
        let defaults = ProjectOutputSettings()
        try check(defaults.showsSampleLoader, "sample menu must be visible by default")

        let legacy = Data("""
        {"isTimecodeBurnEnabled":true,"isFileRenameEnabled":true,
         "showsTimecodeDiagnosticsDetails":true,"renamePrefix":"TEST_"}
        """.utf8)
        let migrated = try decoder.decode(ProjectOutputSettings.self, from: legacy)
        try check(migrated.showsSampleLoader, "old settings must default to a visible sample menu")
        try check(migrated.isTimecodeBurnEnabled && migrated.isFileRenameEnabled
                  && migrated.showsTimecodeDiagnosticsDetails && migrated.renamePrefix == "TEST_",
                  "reading old settings must preserve existing preferences")
        for visible in [false, true] {
            var settings = migrated
            settings.showsSampleLoader = visible
            let data = try JSONEncoder().encode(settings)
            let restored = try decoder.decode(ProjectOutputSettings.self, from: data)
            try check(restored == settings, "both sample-menu states must survive a settings round trip")
        }
        let model = AnalysisViewModel()
        try check(model.mediaItems.isEmpty && model.selectedMediaItemID == nil && model.player == nil,
                  "a new session must start with an empty media queue and no player")
        print("Project settings passed: empty startup, default visibility, legacy settings and visibility persistence")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsError.failed(message) }
    }
}

private enum SettingsError: Error {
    case failed(String)
}
