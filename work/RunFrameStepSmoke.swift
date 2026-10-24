// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AVFoundation
import Foundation

@main
struct RunFrameStepSmoke {
    @MainActor
    static func main() async throws {
        try verifyKeyboardRouting()
        try await verifyHeldKeyTiming()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let bundled = [
            "qtake_A001_bottom_left_24fps.mov",
            "qtake_B014_upper_right_25fps.mov",
            "qtake_C003_bottom_right_30fps.mov",
            "qtake_D009_center_top_24fps.mov"
        ].map { root.appendingPathComponent("Aquarius/Samples/\($0)") }
        for url in bundled + CommandLine.arguments.dropFirst().map({ URL(fileURLWithPath: $0) }) {
            try await verifyFrameStepping(url: url)
        }
        print("Frame stepping regression passed")
    }

    @MainActor
    private static func verifyKeyboardRouting() throws {
        _ = NSApplication.shared
        let window = KeyboardTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = FrameStepKeyView()
        window.contentView?.addSubview(view)
        var steps: [Int] = []
        view.isEnabled = { true }
        view.onStep = { steps.append($0) }
        func event(_ code: UInt16, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code
            )!
        }
        try check(view.handleKeyDown(event(124)) == nil, "right arrow must be consumed")
        try check(view.handleKeyUp(keyEvent(124, type: .keyUp, window: window)) == nil, "right key-up must be consumed")
        try check(view.handleKeyDown(event(123)) == nil, "left arrow must be consumed")
        try check(view.handleKeyUp(keyEvent(123, type: .keyUp, window: window)) == nil, "left key-up must be consumed")
        try check(steps == [1, -1], "each arrow press must issue exactly one frame step")
        try check(view.handleKeyDown(event(124, repeatKey: true)) == nil, "held-key repeat must be consumed")
        try check(steps == [1, -1], "held-key repeat must not advance another frame")
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            try check(view.handleKeyDown(event(124, flags: flags)) != nil, "modified arrows must pass through")
        }
        try check(view.handleKeyDown(event(49)) != nil, "other playback shortcuts must pass through")
        let editor = NSTextView()
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        try check(view.handleKeyDown(event(124)) != nil, "text editing must retain arrow keys")
        window.makeFirstResponder(nil)
        view.isEnabled = { false }
        try check(view.handleKeyDown(event(124)) != nil, "unloaded player must not consume arrows")
        view.isEnabled = { true }
        window.testIsKeyWindow = false
        try check(view.handleKeyDown(event(124)) != nil, "inactive windows must not step")
        try check(steps == [1, -1], "routing exclusions must not issue frame steps")
        view.removeFromSuperview()
        print("Keyboard routing passed: arrows, repeat suppression, modifiers, text editing, inactive and unloaded states")
        fflush(stdout)
    }

    @MainActor
    private static func keyEvent(_ code: UInt16, type: NSEvent.EventType = .keyDown, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        )!
    }

    @MainActor
    private static func verifyHeldKeyTiming() async throws {
        let window = KeyboardTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = FrameStepKeyView()
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        var readings: [(Int, Double)] = []
        view.isEnabled = { true }
        view.onStep = { readings.append(($0, ProcessInfo.processInfo.systemUptime)) }

        _ = view.handleKeyDown(keyEvent(124, window: window))
        _ = view.handleKeyUp(keyEvent(124, type: .keyUp, window: window))
        try await Task.sleep(for: .milliseconds(500))
        try check(readings.count == 1, "a tap must remain one frame after the hold threshold")
        for (code, direction) in [(UInt16(124), 1), (UInt16(123), -1)] {
            let baseline = readings.count
            _ = view.handleKeyDown(keyEvent(code, window: window))
            try await waitUntil("eight held-key repeat frames") { readings.count >= baseline + 9 }
            _ = view.handleKeyUp(keyEvent(code, type: .keyUp, window: window))
            let repeats = Array(readings[(baseline + 1)...])
            let elapsed = repeats.last!.1 - repeats.first!.1
            try check(repeats.count == 8 && repeats.allSatisfy { $0.0 == direction },
                      "a held arrow must repeat only in its requested direction")
            try check(abs(elapsed - 7.0 / 8.0) < 0.2, "held-key repeat must run at 8 fps")
            let releasedCount = readings.count
            try await Task.sleep(for: .milliseconds(250))
            try check(readings.count == releasedCount, "release must stop all repeat frames")
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            _ = view.handleKeyDown(keyEvent(124, window: window))
            let stoppedCount = readings.count
            NotificationCenter.default.post(name: name, object: name == NSWindow.didResignKeyNotification ? window : NSApp)
            try await Task.sleep(for: .milliseconds(450))
            try check(readings.count == stoppedCount, "focus loss must stop held-key playback")
        }
        _ = view.handleKeyDown(keyEvent(124, window: window))
        let switchedCount = readings.count
        view.playbackID = ObjectIdentifier(window)
        try await Task.sleep(for: .milliseconds(450))
        try check(readings.count == switchedCount, "switching media must cancel held-key playback")
        print("Held-key playback passed: single taps, 8 fps both directions, release, focus loss and media switch")
        fflush(stdout)
    }

    @MainActor
    private static func verifyFrameStepping(url: URL) async throws {
        let model = AnalysisViewModel()
        model.addDroppedURLs([url])
        guard let player = model.player, let item = player.currentItem else {
            throw FrameStepError.failed("no player for \(url.lastPathComponent)")
        }
        try await waitUntil("player readiness") {
            item.status == .readyToPlay && model.videoPlaybackFrameRate > 0 && item.canStepForward
        }
        let track = try await item.asset.loadTracks(withMediaType: .video).first!
        let frameDuration = try await track.load(.minFrameDuration)
        try check(frameDuration.isNumeric && frameDuration.seconds > 0, "fixture must have a video frame duration")
        // Deliberately choose a different TC base; movement must use video frames.
        model.sourceTimecodeFrameRateSetting = .fps30
        try await seek(model, to: .zero)
        try await step(model, by: 1, frameDuration: frameDuration)
        try await waitUntil("frame badge F1") { model.currentFrameText == "1" }
        try await step(model, by: 1, frameDuration: frameDuration)
        try await step(model, by: -1, frameDuration: frameDuration)

        try await seek(model, to: .zero)
        for _ in 0..<5 { model.stepFrame(by: 1) }
        try await waitUntil("five rapid presses") {
            abs(player.currentTime().seconds - frameDuration.seconds * 5) < clockTolerance(player)
        }
        try await waitUntil("frame badge F5") { model.currentFrameText == "5" }
        try check(player.rate == 0 && !model.isPlaying, "stepping must leave playback paused")
        for _ in 0..<5 { model.stepFrame(by: -1) }
        try await waitUntil("five rapid backward presses") {
            abs(player.currentTime().seconds) < clockTolerance(player)
        }
        try await verifyHeldFrames(model, frameDuration: frameDuration)

        player.play()
        model.isPlaying = true
        model.stepFrame(by: 1)
        try check(player.rate == 0 && !model.isPlaying, "an arrow must pause active playback")
        try await seek(model, to: .zero)
        model.stepFrame(by: -1)
        try await Task.sleep(for: .milliseconds(100))
        try check(abs(player.currentTime().seconds) < clockTolerance(player),
                  "left at the first frame must stay at the first frame")

        let range = try await track.load(.timeRange)
        let lastFrame = CMTimeSubtract(CMTimeRangeGetEnd(range), frameDuration)
        try await seek(model, to: lastFrame)
        try await step(model, by: -1, frameDuration: frameDuration)
        try await step(model, by: 1, frameDuration: frameDuration)
        model.stepFrame(by: 1)
        try await Task.sleep(for: .milliseconds(100))
        try check(player.currentTime().seconds <= CMTimeRangeGetEnd(range).seconds + clockTolerance(player),
                  "right at the last frame must not go beyond the video")
        model.seekToEnd()
        try await waitUntil("end seek") { player.currentTime().seconds >= lastFrame.seconds - clockTolerance(player) }
        model.stepFrame(by: -1)
        let penultimateFrame = CMTimeSubtract(lastFrame, frameDuration)
        try await waitUntil("left from end") {
            abs(player.currentTime().seconds - penultimateFrame.seconds) < clockTolerance(player)
        }
        model.clearMediaList()
        print("\(url.lastPathComponent): one-frame forward/backward, rapid presses, pause, boundaries and frame badge passed")
        fflush(stdout)
    }

    @MainActor
    private static func verifyHeldFrames(_ model: AnalysisViewModel, frameDuration: CMTime) async throws {
        let window = KeyboardTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = FrameStepKeyView()
        window.contentView?.addSubview(view)
        defer { view.removeFromSuperview() }
        view.isEnabled = { model.canStepVideoFrames }
        view.onStep = { model.stepFrame(by: $0) }
        _ = view.handleKeyDown(keyEvent(124, window: window))
        try await waitUntil("five held frames") { model.currentFrameText == "5" }
        _ = view.handleKeyUp(keyEvent(124, type: .keyUp, window: window))
        let player = model.player!
        try await waitUntil("held-frame video seek") {
            abs(player.currentTime().seconds - frameDuration.seconds * 5) < clockTolerance(player)
        }
        try await Task.sleep(for: .milliseconds(200))
        try check(model.currentFrameText == "5" && player.rate == 0,
                  "video must stay paused on the released frame")
    }

    @MainActor
    private static func step(_ model: AnalysisViewModel, by count: Int, frameDuration: CMTime) async throws {
        let player = model.player!
        let expected = CMTimeAdd(player.currentTime(), CMTimeMultiply(frameDuration, multiplier: Int32(count)))
        model.stepFrame(by: count)
        do {
            try await waitUntil("one-frame step \(count)") {
                abs(player.currentTime().seconds - expected.seconds) < clockTolerance(player)
            }
        } catch {
            throw FrameStepError.failed(
                "step \(count): expected \(expected.seconds), actual \(player.currentTime().seconds), frame duration \(frameDuration.seconds), canStepForward \(player.currentItem?.canStepForward == true)"
            )
        }
    }

    @MainActor
    private static func seek(_ model: AnalysisViewModel, to time: CMTime) async throws {
        model.seek(to: time.seconds)
        do {
            try await waitUntil("test seek") {
                abs((model.player?.currentTime().seconds ?? -1) - time.seconds) < clockTolerance(model.player!)
            }
        } catch {
            throw FrameStepError.failed("seek: expected \(time.seconds), actual \(model.player?.currentTime().seconds ?? -1), duration \(model.playbackDuration), rate \(model.videoPlaybackFrameRate)")
        }
    }

    @MainActor
    private static func clockTolerance(_ player: AVPlayer) -> Double {
        // Allow one native timestamp tick, still much smaller than a video frame.
        min(0.001, max(0.00001, 1.0 / Double(max(1, player.currentTime().timescale)) + 0.00000001))
    }

    @MainActor
    private static func waitUntil(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FrameStepError.failed("timed out waiting for \(label)")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw FrameStepError.failed(message) }
    }
}

private final class KeyboardTestWindow: NSWindow {
    var testIsKeyWindow = true
    override var isKeyWindow: Bool { testIsKeyWindow }
}

private enum FrameStepError: Error {
    case failed(String)
}
