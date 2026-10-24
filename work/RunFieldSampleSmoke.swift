// SPDX-License-Identifier: GPL-3.0-only

import AVFoundation
import Foundation

// External camera footage stays outside Git. Expected values below were read
// from the first encoded video frames, not from MOV metadata or OCR output.
@main
struct RunFieldSampleSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            print("Usage: field-sample-smoke <sample-directory> [--baseline]")
            exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let baseline = CommandLine.arguments.contains("--baseline")
        let expected = [
            "Tk1_A": "13:23:19:15", "Tk1_B": "13:23:19:14", "Tk1_C": "13:23:19:14",
            "Tk2_A": "13:23:44:13", "Tk2_B": "13:23:44:13", "Tk2_C": "13:23:44:12",
            "Tk3_A": "13:25:40:20", "Tk3_B": "13:25:40:20", "Tk3_C": "13:25:40:21",
            "Tk4_A": "13:26:02:09", "Tk4_B": "13:26:02:08", "Tk4_C": "13:26:02:09",
            "Tk5_A": "13:26:25:02", "Tk5_B": "13:26:25:02", "Tk5_C": "13:26:25:02"
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "mov" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let layouts: [(String, CGRect)] = [
            ("tight", CGRect(x: 0.840, y: 0.960, width: 0.115, height: 0.039)),
            ("with-label", CGRect(x: 0.795, y: 0.960, width: 0.160, height: 0.039))
        ]
        var failures: [String] = []
        var count = 0
        var recognizedCount = 0
        var reviewCount = 0
        for url in urls {
            guard let key = expected.keys.first(where: { url.lastPathComponent.contains($0) }),
                  let expectedTC = expected[key] else {
                continue
            }
            for (layout, rect) in layouts {
                let region = OCRRegion(id: "field-tc", label: "时间码", kind: .timecode, normalizedRect: rect)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                generator.apertureMode = .encodedPixels
                let firstFrame = try await generator.ocrTimecodeCGImage(at: .zero)
                let processor = ROIImageProcessor()
                guard let crop = processor.crop(firstFrame.image, to: rect, kind: .timecode),
                      let preprocessed = processor.preprocess(crop, variant: .balanced) else {
                    print("FAIL: could not crop \(key) \(layout)")
                    exit(1)
                }
                let firstTC = try VisionTextRecognizer().recognize(preprocessed, kind: .timecode)
                let result = try await OCRClipAnalyzer().analyze(
                    url: url,
                    regions: [region],
                    sourceTimecodeFrameRateSetting: .automatic
                )
                count += 1
                let actual = result.startTimecode?.description ?? "nil"
                let ordered = zip(result.samples, result.samples.dropFirst())
                    .allSatisfy { $0.actualSeconds <= $1.actualSeconds }
                let invalid = result.samples.filter { $0.timecodeSampleStatus == .invalid }.count
                let malformed = result.samples.filter { Timecode.parse($0.text, fps: 25) == nil }.count
                recognizedCount += result.samples.count - malformed
                if result.confidence < 0.82 { reviewCount += 1 }
                print("\(key) \(layout): TC=\(actual), fps=\(result.fps), \(result.statusTitle), confidence=\(String(format: "%.3f", result.confidence)), samples=\(result.samples.count), invalid=\(invalid), ordered=\(ordered)")
                fflush(stdout)
                // These monitor recordings repeat/skip burned-in TC labels.
                // Test recognition independently of the continuity safety gate.
                if firstFrame.actualTime != .zero || firstTC.text != expectedTC
                    || result.fps != 25 || malformed > 0 || result.samples.isEmpty || !ordered
                    || (invalid > 0 && result.confidence >= 0.82) {
                    failures.append("\(key) \(layout): expected first frame \(expectedTC) at 25fps, got \(firstTC.text) at \(result.fps)fps; malformed=\(malformed), ordered=\(ordered), confidence=\(result.confidence)")
                }
                if baseline {
                    print(result.samples.prefix(6).map { "\(String(format: "%.3f", $0.actualSeconds))s \($0.rawText)" }.joined(separator: " | "))
                }
            }
        }
        guard count == expected.count * layouts.count else {
            print("FAIL: expected 30 analyses, ran \(count)")
            exit(1)
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("Field OCR/ordering regression: \(count - failures.count)/\(count) passed; \(recognizedCount) valid SMPTE readings; \(reviewCount) analyses require review")
        if !baseline, !failures.isEmpty { exit(1) }
    }
}
