// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

nonisolated private struct EventMonitorToken: @unchecked Sendable {
    let value: Any
}

struct ProjectSettingsKeyHandler: NSViewRepresentable {
    let onOpen: () -> Void

    func makeNSView(context: Context) -> ProjectSettingsKeyView {
        ProjectSettingsKeyView()
    }

    func updateNSView(_ nsView: ProjectSettingsKeyView, context: Context) {
        nsView.onOpen = onOpen
    }
}

final class ProjectSettingsKeyView: NSView {
    var onOpen: () -> Void = {}
    nonisolated(unsafe) private var keyMonitor: EventMonitorToken?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor.value)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyDown(event) == nil
            }
            return handled ? nil : event
        }) {
            keyMonitor = EventMonitorToken(value: token)
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor.value) }
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else {
            return event
        }

        // Match both input-method output and the physical grave key, with or without Shift.
        let aliases: Set<String> = ["·", "～", "`", "~"]
        guard event.keyCode == 50
                || aliases.contains(event.characters ?? "")
                || aliases.contains(event.charactersIgnoringModifiers ?? "") else {
            return event
        }
        if !event.isARepeat { onOpen() }
        return nil
    }
}
