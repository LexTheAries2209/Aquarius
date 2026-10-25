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
        try check(defaults.showsMetadataEditor, "metadata editor must be visible by default")
        try check(defaults.startupEnabledFieldKinds == Set(OCRFieldKind.allCases),
                  "all OCR fields must be enabled until startup defaults are configured")

        let legacy = Data("""
        {"isTimecodeBurnEnabled":true,"isFileRenameEnabled":true,
         "showsTimecodeDiagnosticsDetails":true,"renamePrefix":"TEST_"}
        """.utf8)
        let migrated = try decoder.decode(ProjectOutputSettings.self, from: legacy)
        try check(migrated.showsSampleLoader, "old settings must default to a visible sample menu")
        try check(migrated.showsMetadataEditor, "old settings must default to a visible metadata editor")
        try check(migrated.startupEnabledFieldKinds == Set(OCRFieldKind.allCases),
                  "old settings must continue to enable all OCR fields")
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
        for visible in [false, true] {
            var settings = migrated
            settings.showsMetadataEditor = visible
            let data = try JSONEncoder().encode(settings)
            let restored = try decoder.decode(ProjectOutputSettings.self, from: data)
            try check(restored == settings, "both metadata editor visibility states must survive a settings round trip")
        }
        let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = AnalysisViewModel(applicationSupportURL: testRoot.appendingPathComponent("empty"))
        try check(model.mediaItems.isEmpty && model.selectedMediaItemID == nil && model.player == nil,
                  "a new session must start with an empty media queue and no player")
        try check(model.enabledFieldKinds == Set(OCRFieldKind.allCases), "a fresh session must enable all OCR fields")
        print("Project settings passed: empty startup, default visibility, legacy settings and visibility persistence")
        try verifySamplePanelSizing()
        try verifyStartupFields(in: testRoot, legacySettings: legacy)
        try verifyKeyboardRouting()
    }

    private static func verifySamplePanelSizing() throws {
        for (windowHeight, columnHeight) in [
            (920.0, 856.0),
            (680.0, 616.0),
            (1_400.0, 1_336.0)
        ] {
            let maximum = OCRSamplePanelSizing.maximumHeight(
                windowContentHeight: windowHeight,
                columnHeight: columnHeight
            )
            try check(maximum <= windowHeight * 0.5,
                      "the sample panel must never exceed half the window height")
            try check(columnHeight - maximum - OCRSamplePanelSizing.dividerHeight
                      >= OCRSamplePanelSizing.minimumVideoWorkspaceHeight,
                      "resizing must retain minimum playback workspace height")
            try check(OCRSamplePanelSizing.clampedHeight(-100, maximumHeight: maximum)
                      == OCRSamplePanelSizing.minimumHeight,
                      "dragging below the minimum must keep samples readable")
            try check(OCRSamplePanelSizing.clampedHeight(10_000, maximumHeight: maximum)
                      == maximum,
                      "dragging above the limit must clamp at the available maximum")
            try check(OCRSamplePanelSizing.clampedHeight(250, maximumHeight: maximum) == 250,
                      "in-range sample panel heights must be retained")
        }
        let narrowWindowMaximum = OCRSamplePanelSizing.maximumHeight(windowContentHeight: 500, columnHeight: 300)
        try check(narrowWindowMaximum == 50,
                  "a narrow video column must further constrain the window half-height limit")
        try check(OCRSamplePanelSizing.clampedHeight(300, maximumHeight: narrowWindowMaximum) == 50,
                  "window resizing must visually clamp a saved height to the current available space")
        print("OCR sample panel sizing passed: window half-height cap, playback minimum, drag bounds and resize clamp")
    }

    @MainActor
    private static func verifyStartupFields(in testRoot: URL, legacySettings: Data) throws {
        let supportURL = testRoot.appendingPathComponent("startup-fields", isDirectory: true)
        let storeDirectory = supportURL.appendingPathComponent("Aquarius", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let settingsURL = storeDirectory.appendingPathComponent("ProjectOutputSettings.json")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        try legacySettings.write(to: settingsURL)
        let legacyModel = AnalysisViewModel(applicationSupportURL: supportURL)
        try check(legacyModel.enabledFieldKinds == Set(OCRFieldKind.allCases)
                  && legacyModel.isTimecodeBurnOptionEnabled && legacyModel.renameOutputPrefix == "TEST_",
                  "a legacy settings file must preserve preferences and enable every OCR field")

        // Cover every field combination, including an explicitly empty selection.
        for mask in 0..<8 {
            let wanted = Set(OCRFieldKind.allCases.enumerated().compactMap { index, kind in
                mask & (1 << index) != 0 ? kind : nil
            })
            let settings = ProjectOutputSettings(
                showsSampleLoader: false,
                showsMetadataEditor: false,
                startupEnabledFieldKinds: wanted
            )
            try encoder.encode(settings).write(to: settingsURL)
            let model = AnalysisViewModel(applicationSupportURL: supportURL)
            try check(model.startupEnabledFieldKinds == wanted && model.enabledFieldKinds == wanted,
                      "launch must restore the exact saved field selection for mask \(mask)")
            try check(Set(model.enabledRegions.map(\.kind)) == wanted && model.hasEnabledFields == !wanted.isEmpty,
                      "OCR regions and analysis availability must match the startup selection")
            if !wanted.isEmpty {
                try check(model.enabledRegions.contains { $0.id == model.selectedRegionID },
                          "launch must select an enabled ROI even without saved ROI presets")
            }
            model.setField(.clipName, isEnabled: !wanted.contains(.clipName))
            let unchanged = try decoder.decode(ProjectOutputSettings.self, from: Data(contentsOf: settingsURL))
            try check(unchanged == settings, "session field switches must not overwrite startup settings")
            model.renameOutputPrefix = "SESSION_"
            let relaunched = AnalysisViewModel(applicationSupportURL: supportURL)
            try check(relaunched.enabledFieldKinds == wanted && relaunched.startupEnabledFieldKinds == wanted,
                      "saving another preference must not persist temporary session switches")
            try check(!relaunched.showsSampleLoader && !relaunched.showsMetadataEditor
                      && relaunched.renameOutputPrefix == "SESSION_",
                      "saving startup fields must preserve other preferences")
        }

        try encoder.encode(ProjectOutputSettings(startupEnabledFieldKinds: [.timecode])).write(to: settingsURL)
        let model = AnalysisViewModel(applicationSupportURL: supportURL)
        model.setStartupField(.roll, isEnabled: true)
        model.setStartupField(.timecode, isEnabled: false)
        try check(model.enabledFieldKinds == [.timecode], "editing startup defaults must not change the active session")
        let relaunched = AnalysisViewModel(applicationSupportURL: supportURL)
        try check(relaunched.enabledFieldKinds == [.roll], "startup toggles must persist and apply at the next launch")
        try check(relaunched.errorMessage == nil, "saving startup defaults must not fail")

        let customTimecode = OCRRegion(
            id: "custom-timecode", label: "TC", kind: .timecode,
            normalizedRect: CGRect(x: 0.7, y: 0.9, width: 0.2, height: 0.08)
        )
        let presets = [ROIPreset(name: "Custom", regions: [OCRRegion.qtakeLowerLeftPreset[0], customTimecode])]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(presets).write(to: storeDirectory.appendingPathComponent("ROIPresets.json"))
        try encoder.encode(ProjectOutputSettings(startupEnabledFieldKinds: [.timecode])).write(to: settingsURL)
        let customModel = AnalysisViewModel(applicationSupportURL: supportURL)
        try check(customModel.enabledRegions.map(\.id) == [customTimecode.id] && customModel.selectedRegionID == customTimecode.id,
                  "saved ROI presets must also select and enable only the requested startup fields")
        print("Startup fields passed: eight combinations, legacy settings, disk persistence, session independence and default/custom ROI selection")
    }

    @MainActor
    private static func verifyKeyboardRouting() throws {
        _ = NSApplication.shared
        let window = SettingsTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = ProjectSettingsKeyView()
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        var openedCount = 0
        view.onOpen = { openedCount += 1 }
        func event(
            _ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [],
            repeated: Bool = false, target: NSWindow? = nil
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: (target ?? window).windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeated, keyCode: code
            )!
        }
        for alias in ["·", "～", "`", "~"] {
            try check(view.handleKeyDown(event(alias)) == nil, "each character alias must open settings")
        }
        try check(openedCount == 4, "each shortcut press must open settings once")
        try check(view.handleKeyDown(event("", code: 50)) == nil, "physical grave key must work across input methods")
        try check(view.handleKeyDown(event("~", code: 50, flags: .shift)) == nil, "Shift-grave must open settings")
        try check(view.handleKeyDown(event("~", code: 50, flags: .shift, repeated: true)) == nil,
                  "held settings shortcut must consume repeat events")
        try check(openedCount == 6, "key repeats must not reopen settings")

        for flag: NSEvent.ModifierFlags in [.command, .option, .control] {
            try check(view.handleKeyDown(event("`", code: 50, flags: flag)) != nil,
                      "modified grave shortcuts must retain their system or text behavior")
        }
        try check(view.handleKeyDown(event("p", code: 35, flags: .command)) != nil, "Command-P is no longer settings")
        try check(view.handleKeyDown(event("x", code: 7)) != nil, "ordinary keys must pass through")
        let editor = NSTextView()
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        for alias in ["·", "～", "`", "~"] {
            try check(view.handleKeyDown(event(alias, code: 50)) != nil, "text editing must retain all shortcut characters")
        }
        window.makeFirstResponder(nil)
        window.testIsKeyWindow = false
        try check(view.handleKeyDown(event("`", code: 50)) != nil, "inactive window must not handle the shortcut")
        window.testIsKeyWindow = true
        let otherWindow = SettingsTestWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false
        )
        try check(view.handleKeyDown(event("`", code: 50, target: otherWindow)) != nil,
                  "another window's events must pass through")
        window.testHasSheet = true
        try check(view.handleKeyDown(event("`", code: 50)) != nil, "a settings or import sheet must retain its own input")
        window.testHasSheet = false
        try check(openedCount == 6, "routing exclusions must not open settings")

        // Exercise the installed monitor and its teardown, not only the event matcher.
        NSApp.sendEvent(event("`", code: 50))
        try check(openedCount == 7, "the local key monitor must route shortcuts")
        view.removeFromSuperview()
        NSApp.sendEvent(event("`", code: 50))
        try check(openedCount == 7, "detaching the bridge must remove its monitor")
        print("Settings shortcuts passed: four aliases, Shift, physical key, repeat suppression, editing, focus, sheets and monitor lifecycle")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsError.failed(message) }
    }
}

private enum SettingsError: Error {
    case failed(String)
}

private final class SettingsTestWindow: NSWindow {
    var testIsKeyWindow = true
    var testHasSheet = false
    private lazy var testSheet = NSWindow()

    override var isKeyWindow: Bool { testIsKeyWindow }
    override var attachedSheet: NSWindow? { testHasSheet ? testSheet : nil }
}
