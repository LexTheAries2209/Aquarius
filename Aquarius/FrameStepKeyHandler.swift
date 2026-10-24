// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

struct FrameStepKeyHandler: NSViewRepresentable {
    let isEnabled: () -> Bool
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> FrameStepKeyView {
        FrameStepKeyView()
    }

    func updateNSView(_ nsView: FrameStepKeyView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onStep = onStep
    }
}

final class FrameStepKeyView: NSView {
    var isEnabled: () -> Bool = { false }
    var onStep: (Int) -> Void = { _ in }
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handleKeyDown(event) == nil
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.keyCode == 123 || event.keyCode == 124,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window, window.isKeyWindow, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !(window.firstResponder is NSTextView),
              !(window.firstResponder is NSTextField),
              isEnabled() else {
            return event
        }
        // Consume held-key repeats without stepping: one physical press is one frame.
        if !event.isARepeat {
            onStep(event.keyCode == 123 ? -1 : 1)
        }
        return nil
    }
}
