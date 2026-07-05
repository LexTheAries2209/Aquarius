// SPDX-License-Identifier: GPL-3.0-only

import Foundation

@main
struct RunTMCDCopySmoke {
    static func main() async throws {
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sourceURL = projectRoot
            .appendingPathComponent("Aquarius", isDirectory: true)
            .appendingPathComponent("Samples", isDirectory: true)
            .appendingPathComponent("qtake_A001_bottom_left_24fps.mov")
        let outputDirectory = projectRoot
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("tmcd_copy_smoke_outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let outputURL = outputDirectory.appendingPathComponent("qtake_A001_copy_added_tmcd.mov")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        print("source has writable tmcd: \(QuickTimeTMCDWriter.hasWritableTMCDTrack(in: sourceURL))")
        let report = try await QuickTimeTMCDWriter.copyAddingStartTimecode(
            Timecode(hours: 10, minutes: 0, seconds: 0, frames: 0, fps: 24),
            from: sourceURL,
            to: outputURL
        )
        print("new tc: \(report.newFirstFrame) -> \(report.newLastFrame), fps \(report.newFrameRate)")
        print("output has writable tmcd: \(QuickTimeTMCDWriter.hasWritableTMCDTrack(in: outputURL))")

        guard QuickTimeTMCDWriter.hasWritableTMCDTrack(in: outputURL) else {
            throw SmokeError.noWritableTMCD
        }
    }
}

private enum SmokeError: Error {
    case noWritableTMCD
}
