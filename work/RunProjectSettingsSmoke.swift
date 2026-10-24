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
        try verifyKeyboardRouting()
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
