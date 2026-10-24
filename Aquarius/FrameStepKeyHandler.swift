// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI

struct FrameStepKeyHandler: NSViewRepresentable {
    let isEnabled: () -> Bool
    let onStep: (Int) -> Void
    let playbackID: ObjectIdentifier?

    func makeNSView(context: Context) -> FrameStepKeyView {
        FrameStepKeyView()
    }

    func updateNSView(_ nsView: FrameStepKeyView, context: Context) {
        nsView.playbackID = playbackID
        nsView.isEnabled = isEnabled
        nsView.onStep = onStep
    }
}

final class FrameStepKeyView: NSView {
    var isEnabled: () -> Bool = { false }
    var onStep: (Int) -> Void = { _ in }
    var playbackID: ObjectIdentifier? {
        didSet {
            if oldValue != playbackID { stopHeldKey() }
        }
    }
    private var keyMonitor: Any?
    private var heldKeyCode: UInt16?
    private var holdTask: Task<Void, Never>?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopHeldKey()
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(stopForNotification(_:)), name: name, object: window)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(stopForNotification(_:)),
            name: NSApplication.didResignActiveNotification, object: NSApp
        )
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                switch event.type {
                case .keyDown:
                    return self.handleKeyDown(event) == nil
                case .keyUp:
                    return self.handleKeyUp(event) == nil
                case .flagsChanged:
                    if !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                        self.stopHeldKey()
                    }
                default:
                    self.stopHeldKey()
                }
                return false
            }
            return handled ? nil : event
        }
    }

    deinit {
        holdTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.keyCode == 123 || event.keyCode == 124,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              event.window === window, canHandleInput else {
            stopHeldKey()
            return event
        }
        // OS repeat events are consumed; our own clock defines the 8 fps rate.
        if event.isARepeat { return nil }
        stopHeldKey()
        heldKeyCode = event.keyCode
        onStep(event.keyCode == 123 ? -1 : 1)
        let keyCode = event.keyCode
        holdTask = Task { @MainActor [weak self] in
            do {
                // A quick tap remains a single frame.
                let clock = ContinuousClock()
                var deadline = clock.now.advanced(by: .milliseconds(350))
                while !Task.isCancelled {
                    try await clock.sleep(until: deadline)
                    guard self?.repeatHeldKey(keyCode) == true else { return }
                    deadline = deadline.advanced(by: .milliseconds(125))
                    // Never burst through missed ticks after a blocked UI.
                    if deadline < clock.now { deadline = clock.now.advanced(by: .milliseconds(125)) }
                }
            } catch {
                // Releasing the key or leaving the player cancels the clock.
            }
        }
        return nil
    }

    func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyUp, event.keyCode == heldKeyCode else { return event }
        stopHeldKey()
        return nil
    }

    private var canHandleInput: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.attachedSheet == nil && NSApp.modalWindow == nil
            && !(window.firstResponder is NSTextView) && !(window.firstResponder is NSTextField)
            && isEnabled()
    }

    private func repeatHeldKey(_ keyCode: UInt16) -> Bool {
        guard heldKeyCode == keyCode, canHandleInput else {
            stopHeldKey()
            return false
        }
        onStep(keyCode == 123 ? -1 : 1)
        return true
    }

    @objc private func stopForNotification(_ notification: Notification) {
        stopHeldKey()
    }

    private func stopHeldKey() {
        holdTask?.cancel()
        holdTask = nil
        heldKeyCode = nil
    }
}
