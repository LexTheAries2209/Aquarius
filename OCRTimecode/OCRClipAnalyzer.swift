import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

enum AVAssetFrameExtractionError: LocalizedError {
    case noImage

    nonisolated var errorDescription: String? {
        switch self {
        case .noImage:
            "无法从视频中生成预览帧"
        }
    }
}

extension AVAssetImageGenerator {
    nonisolated func ocrTimecodeCGImage(at requestedTime: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await withCheckedThrowingContinuation { continuation in
            generateCGImageAsynchronously(for: requestedTime) { image, actualTime, error in
                if let image {
                    continuation.resume(returning: (image, actualTime))
                } else {
                    continuation.resume(throwing: error ?? AVAssetFrameExtractionError.noImage)
                }
            }
        }
    }
}

struct OCRClipAnalyzer {
    private let maximumSamplePointCount = 50
    private let denseSamplingDurationLimit = 10.0 * 60.0
    private let denseSamplesPerMinute = 5.0
    private let imageProcessor = ROIImageProcessor()
    private let recognizer = VisionTextRecognizer()

    nonisolated init() {}

    nonisolated func analyze(
        url: URL,
        regions: [OCRRegion],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) async throws -> ClipOCRResult {
        let asset = AVURLAsset(url: url)
        let videoFrameRate = try await detectFrameRate(asset: asset)
        let duration = safeDuration(try await asset.load(.duration).seconds)
        let sampleTimes = buildBaseSampleTimes(duration: duration)
        let expectedKinds = Set(regions.map(\.kind))
        let generator = AVAssetImageGenerator(asset: asset)

        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.apertureMode = .encodedPixels

        var samples = await collectSamples(
            at: sampleTimes,
            generator: generator,
            regions: regions
        )
        var result = OCRConsensusResolver.resolve(
            videoName: url.lastPathComponent,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
            duration: duration,
            samples: samples,
            expectedKinds: expectedKinds
        )

        let nearbySampleTimes = buildNearbySampleTimes(
            from: samples,
            result: result,
            duration: duration,
            existingTimes: sampleTimes,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting
        )

        if !nearbySampleTimes.isEmpty {
            samples.append(
                contentsOf: await collectSamples(
                    at: nearbySampleTimes,
                    generator: generator,
                    regions: regions
                )
            )
            result = OCRConsensusResolver.resolve(
                videoName: url.lastPathComponent,
                videoFrameRate: videoFrameRate,
                sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
                duration: duration,
                samples: samples,
                expectedKinds: expectedKinds
            )
        }

        return result
    }

    nonisolated private func collectSamples(
        at sampleTimes: [Double],
        generator: AVAssetImageGenerator,
        regions: [OCRRegion]
    ) async -> [OCRSample] {
        var samples: [OCRSample] = []

        for seconds in sampleTimes {
            let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let frameResult = try? await generator.ocrTimecodeCGImage(at: requestedTime) else {
                continue
            }
            let frame = frameResult.image
            let actualSeconds = safeDuration(frameResult.actualTime.seconds, fallback: seconds)

            for region in regions {
                guard let crop = imageProcessor.crop(frame, to: region.normalizedRect),
                      let processed = imageProcessor.preprocess(crop) else {
                    continue
                }

                guard let candidate = try? recognizer.recognize(processed, kind: region.kind) else {
                    continue
                }
                samples.append(
                    OCRSample(
                        region: region,
                        requestedSeconds: seconds,
                        actualSeconds: actualSeconds,
                        rawText: candidate.text,
                        confidence: candidate.confidence
                    )
                )
            }
        }

        return samples
    }

    nonisolated private func detectFrameRate(asset: AVAsset) async throws -> Double {
        let nominalFrameRate = try await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate) ?? 24
        let frameRate = Double(nominalFrameRate)
        guard frameRate.isFinite, frameRate > 0 else {
            return 24
        }
        return frameRate
    }

    nonisolated private func buildBaseSampleTimes(duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0.5 else {
            return [0.1]
        }

        let lastSafeTime = max(0.1, duration - 0.6)
        guard duration >= 6 else {
            return uniqueSampleTimes([0.4, duration * 0.5, lastSafeTime], lastSafeTime: lastSafeTime)
        }
        guard duration >= 60 else {
            return uniqueSampleTimes([1.0, duration * 0.40, duration * 0.68], lastSafeTime: lastSafeTime)
        }

        let targetCount = min(maximumSamplePointCount, dynamicSampleCount(for: duration))
        let firstSafeTime = min(max(1.0, duration * 0.01), lastSafeTime)

        if targetCount == 1 || lastSafeTime <= firstSafeTime {
            return [firstSafeTime]
        }

        let span = lastSafeTime - firstSafeTime
        let rawTimes = (0..<targetCount).map { index in
            firstSafeTime + span * Double(index) / Double(targetCount - 1)
        }

        return uniqueSampleTimes(rawTimes, lastSafeTime: lastSafeTime)
    }

    nonisolated private func buildNearbySampleTimes(
        from samples: [OCRSample],
        result: ClipOCRResult,
        duration: Double,
        existingTimes: [Double],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) -> [Double] {
        guard duration.isFinite, duration > 2 else {
            return []
        }

        let weakTimes = weakSampleTimes(
            from: samples,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting
        )
        guard !weakTimes.isEmpty || result.notes.contains(where: isSamplingRelevantNote) else {
            return []
        }

        let lastSafeTime = max(0.1, duration - 0.6)
        let sourceTimes = weakTimes.isEmpty ? existingTimes : weakTimes
        let offsets = [-1.0, 1.0, -2.0, 2.0]
        let remainingSamplePointCount = max(0, maximumSamplePointCount - existingTimes.count)
        let maximumAdditionalCount = min(max(existingTimes.count, 4), remainingSamplePointCount)
        guard maximumAdditionalCount > 0 else {
            return []
        }
        var allKnownTimes = existingTimes
        var nearbyTimes: [Double] = []

        for sourceTime in sourceTimes {
            for offset in offsets {
                let time = min(max(sourceTime + offset, 0.1), lastSafeTime)
                guard !allKnownTimes.contains(where: { abs($0 - time) < 0.25 }),
                      !nearbyTimes.contains(where: { abs($0 - time) < 0.25 }) else {
                    continue
                }
                nearbyTimes.append(time)
                allKnownTimes.append(time)

                if nearbyTimes.count >= maximumAdditionalCount {
                    return nearbyTimes.sorted()
                }
            }
        }

        return nearbyTimes.sorted()
    }

    nonisolated private func dynamicSampleCount(for duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else {
            return 1
        }

        if duration > denseSamplingDurationLimit {
            return maximumSamplePointCount
        }

        return max(3, Int(ceil(duration / 60.0 * denseSamplesPerMinute)))
    }

    nonisolated private func weakSampleTimes(
        from samples: [OCRSample],
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    ) -> [Double] {
        samples
            .filter { sample in
                if sample.region.kind == .clipName {
                    return false
                }
                if sample.confidence < 0.50 || sample.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }

                switch sample.region.kind {
                case .clipName:
                    return OCRFieldParser.clipName(from: sample.rawText) == nil
                case .roll:
                    return OCRFieldParser.roll(from: sample.rawText) == nil
                case .timecode:
                    return !sourceTimecodeFrameRateSetting.candidateFrameRates.contains { fps in
                        OCRFieldParser.timecode(from: sample.rawText, fps: fps) != nil
                    }
                }
            }
            .map(\.actualSeconds)
            .reduce(into: [Double]()) { unique, time in
                if !unique.contains(where: { abs($0 - time) < 0.25 }) {
                    unique.append(time)
                }
            }
    }

    nonisolated private func isSamplingRelevantNote(_ note: String) -> Bool {
        note.contains("卷号") || note.contains("时间码") || note.contains("起始")
    }

    nonisolated private func uniqueSampleTimes(_ rawTimes: [Double], lastSafeTime: Double) -> [Double] {
        rawTimes
            .map { min(max(0.1, $0), lastSafeTime) }
            .reduce(into: [Double]()) { unique, time in
                if !unique.contains(where: { abs($0 - time) < 0.05 }) {
                    unique.append(time)
                }
            }
    }

    nonisolated private func safeDuration(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }
}

private struct ROIImageProcessor {
    private let context = CIContext()

    nonisolated init() {}

    nonisolated func crop(_ image: CGImage, to normalizedRect: CGRect) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let expanded = normalizedRect.insetBy(dx: -0.010, dy: -0.012)
        let clamped = expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let pixelRect = CGRect(
            x: clamped.minX * width,
            y: clamped.minY * height,
            width: clamped.width * width,
            height: clamped.height * height
        ).integral

        return image.cropping(to: pixelRect)
    }

    nonisolated func preprocess(_ image: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: 2.5, y: 2.5))
            .applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputContrastKey: 1.65,
                    kCIInputBrightnessKey: 0.03
                ]
            )
            .applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: 0.75
                ]
            )

        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}

private struct RecognizedTextCandidate {
    let text: String
    let confidence: Double
}

private struct VisionTextRecognizer {
    nonisolated init() {}

    nonisolated func recognize(_ image: CGImage, kind: OCRFieldKind) throws -> RecognizedTextCandidate {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.customWords = customWords(for: kind)
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        let observations = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        let candidates = observations.compactMap { observation in
            observation.topCandidates(1).first
        }

        let text = candidates
            .map(\.string)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let confidence = candidates.isEmpty
            ? 0
            : Double(candidates.map(\.confidence).reduce(0, +)) / Double(candidates.count)

        return RecognizedTextCandidate(text: text, confidence: confidence)
    }

    nonisolated private func customWords(for kind: OCRFieldKind) -> [String] {
        switch kind {
        case .clipName:
            ["A001", "B001", "C001", "QTAKE", "DAILIES"]
        case .roll:
            ["ROLL", "REEL", "A001", "B001", "C001", "QTAKE", "DAILIES"]
        case .timecode:
            ["10:00:00:00", "00:00:00:00"]
        }
    }
}

private enum OCRConsensusResolver {
    nonisolated static func resolve(
        videoName: String,
        videoFrameRate: Double,
        sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting,
        duration: Double,
        samples: [OCRSample],
        expectedKinds: Set<OCRFieldKind>
    ) -> ClipOCRResult {
        let expectsClipName = expectedKinds.contains(.clipName)
        let expectsRoll = expectedKinds.contains(.roll)
        let expectsTimecode = expectedKinds.contains(.timecode)

        let clipNameCandidates = samples
            .filter { $0.region.kind == .clipName }
            .compactMap { OCRFieldParser.clipName(from: $0.rawText) }

        let clipName = expectsClipName ? mostCommon(clipNameCandidates) : nil
        let rollFromClip = expectsRoll ? clipName.flatMap(OCRFieldParser.rollFromClipName) : nil
        let rollSamples = samples.filter { $0.region.kind == .roll }
        let explicitRollCandidates = rollSamples.compactMap { OCRFieldParser.roll(from: $0.rawText) }
        let invalidRollSampleCount = expectsRoll ? rollSamples
            .filter { !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { OCRFieldParser.roll(from: $0.rawText) == nil }
            .count : 0
        let explicitRoll = expectsRoll ? mostCommon(explicitRollCandidates) : nil
        let roll = expectsRoll ? (rollFromClip ?? explicitRoll) : nil

        let timecodeSamples = samples.filter { $0.region.kind == .timecode }
        let timecodeAnalysis = expectsTimecode
            ? analyzeTimecodes(
                samples: timecodeSamples,
                allSamples: samples,
                videoFrameRate: videoFrameRate,
                setting: sourceTimecodeFrameRateSetting
            )
            : nil
        let invalidTimecodeSampleCount = timecodeAnalysis?.invalidSampleCount ?? 0
        let sourceFps = timecodeAnalysis?.sourceFrameRate
            ?? sourceTimecodeFrameRateSetting.fps
            ?? max(1, Int(round(videoFrameRate)))
        let startTimecode = timecodeAnalysis.flatMap { analysis in
            analysis.bestStartFrame.map { Timecode.from(totalFrames: $0, fps: analysis.sourceFrameRate) }
        }

        var notes: [String] = []
        if expectsClipName && clipName == nil {
            notes.append("未稳定识别文件名")
        }
        if expectsRoll && roll == nil {
            notes.append("未稳定识别卷号")
        }
        if expectsRoll && invalidRollSampleCount > 0 {
            notes.append("卷号格式不合法：需类似 A001 或 A_0001_12SQ")
        }
        if expectsTimecode && startTimecode == nil {
            notes.append("未稳定识别起始时间码")
        }
        if expectsTimecode && invalidTimecodeSampleCount > 0 {
            notes.append("时间码格式不合法：需为 HH:MM:SS:FF 且帧号小于源 TC 帧率")
        }
        if let diagnosticNotes = timecodeAnalysis?.diagnostics.notes {
            notes.append(contentsOf: diagnosticNotes)
        }

        let clipScore = score(hasValue: clipName != nil, candidateCount: clipNameCandidates.count)
        let rollScore = score(hasValue: roll != nil, candidateCount: roll == rollFromClip ? clipNameCandidates.count : explicitRollCandidates.count)
        let timecodeScore = timecodeAnalysis.map {
            Double($0.clusteredSampleCount) / Double(max(1, $0.validSampleCount))
        } ?? 0
        let enabledFieldScores = [
            expectsClipName ? clipScore : nil,
            expectsRoll ? rollScore : nil,
            expectsTimecode ? timecodeScore : nil
        ].compactMap(\.self)
        let fieldScore = enabledFieldScores.isEmpty
            ? 0
            : enabledFieldScores.reduce(0, +) / Double(enabledFieldScores.count)
        let ocrScore = samples.isEmpty ? 0 : samples.map(\.confidence).reduce(0, +) / Double(samples.count)
        let hasHighRiskTimecode = timecodeAnalysis?.diagnostics.status == .highRisk
            || timecodeAnalysis?.diagnostics.status == .driftSuspected
        let validationPenalty = invalidRollSampleCount > 0 || invalidTimecodeSampleCount > 0 || hasHighRiskTimecode ? 0.78 : 1.0
        let rawConfidence = fieldScore * 0.75 + ocrScore * 0.25
        let confidence = min(1, max(0, rawConfidence * validationPenalty))

        return ClipOCRResult(
            videoName: videoName,
            fps: sourceFps,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRateSetting: sourceTimecodeFrameRateSetting,
            duration: duration,
            clipName: clipName,
            roll: roll,
            startTimecode: startTimecode,
            confidence: confidence,
            samples: timecodeAnalysis?.annotatedSamples ?? samples,
            timecodeDiagnostics: timecodeAnalysis?.diagnostics,
            notes: notes
        )
    }

    private struct TimecodeReading {
        let sample: OCRSample
        let timecode: Timecode
        let startFrame: Int
    }

    private struct TimecodeAnalysis {
        let sourceFrameRate: Int
        let validSampleCount: Int
        let invalidSampleCount: Int
        let clusteredSampleCount: Int
        let bestStartFrame: Int?
        let annotatedSamples: [OCRSample]
        let diagnostics: TimecodeDiagnostics
    }

    nonisolated private static func analyzeTimecodes(
        samples: [OCRSample],
        allSamples: [OCRSample],
        videoFrameRate: Double,
        setting: SourceTimecodeFrameRateSetting
    ) -> TimecodeAnalysis {
        let candidates = setting.candidateFrameRates.map { fps in
            analyzeCandidate(
                fps: fps,
                samples: samples,
                allSamples: allSamples,
                videoFrameRate: videoFrameRate,
                setting: setting
            )
        }

        guard let best = candidates.max(by: isWorseCandidate) else {
            let diagnostics = TimecodeDiagnostics(
                setting: setting,
                videoFrameRate: videoFrameRate,
                sourceTimecodeFrameRate: setting.fps,
                validSampleCount: 0,
                invalidSampleCount: samples.count,
                maxDeviationFrames: nil,
                driftFramesPerMinute: nil,
                status: .highRisk,
                notes: ["时间码样本不足，无法检测源 TC 帧率"]
            )
            return TimecodeAnalysis(
                sourceFrameRate: setting.fps ?? max(1, Int(round(videoFrameRate))),
                validSampleCount: 0,
                invalidSampleCount: samples.count,
                clusteredSampleCount: 0,
                bestStartFrame: nil,
                annotatedSamples: annotateInvalidTimecodeSamples(allSamples),
                diagnostics: diagnostics
            )
        }

        return best
    }

    nonisolated private static func analyzeCandidate(
        fps: Int,
        samples: [OCRSample],
        allSamples: [OCRSample],
        videoFrameRate: Double,
        setting: SourceTimecodeFrameRateSetting
    ) -> TimecodeAnalysis {
        let nonEmptyTimecodeSampleCount = samples
            .filter { !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
        let readings: [TimecodeReading] = samples.compactMap { sample in
            guard let timecode = OCRFieldParser.timecode(from: sample.rawText, fps: fps) else {
                return nil
            }
            let startFrame = timecode.totalFrames - Int(round(sample.actualSeconds * Double(fps)))
            return TimecodeReading(sample: sample, timecode: timecode, startFrame: startFrame)
        }
        let invalidCount = max(0, nonEmptyTimecodeSampleCount - readings.count)
        let bestFrameCluster = bestFrameCluster(readings.map(\.startFrame))
        let bestStartFrame = bestFrameCluster?.frame
        let deviations = bestStartFrame.map { bestFrame in
            readings.map { $0.startFrame - bestFrame }
        } ?? []
        let maxDeviation = deviations.map { abs($0) }.max()
        let drift = driftFramesPerMinute(from: readings)
        let status = consistencyStatus(
            videoFrameRate: videoFrameRate,
            sourceFrameRate: fps,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            clusteredSampleCount: bestFrameCluster?.count ?? 0,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift
        )
        var notes = diagnosticNotes(
            setting: setting,
            fps: fps,
            samples: samples,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift,
            status: status
        )
        if setting == .automatic, readings.count > 0, bestFrameCluster?.count == readings.count {
            let equallyStable = setting.candidateFrameRates.filter { candidateFPS in
                guard candidateFPS != fps else {
                    return false
                }
                let candidateReadings = samples.compactMap { sample in
                    OCRFieldParser.timecode(from: sample.rawText, fps: candidateFPS)
                }
                return candidateReadings.count == readings.count
            }
            if !equallyStable.isEmpty {
                notes.append("自动帧率可能存在并列结果，已按默认优先级选择 \(fps)")
            }
        }

        let diagnostics = TimecodeDiagnostics(
            setting: setting,
            videoFrameRate: videoFrameRate,
            sourceTimecodeFrameRate: readings.isEmpty ? nil : fps,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            maxDeviationFrames: maxDeviation,
            driftFramesPerMinute: drift,
            status: status,
            notes: notes
        )

        return TimecodeAnalysis(
            sourceFrameRate: fps,
            validSampleCount: readings.count,
            invalidSampleCount: invalidCount,
            clusteredSampleCount: bestFrameCluster?.count ?? 0,
            bestStartFrame: bestStartFrame,
            annotatedSamples: annotateSamples(allSamples, readings: readings, bestStartFrame: bestStartFrame),
            diagnostics: diagnostics
        )
    }

    nonisolated private static func isWorseCandidate(_ lhs: TimecodeAnalysis, _ rhs: TimecodeAnalysis) -> Bool {
        if lhs.clusteredSampleCount != rhs.clusteredSampleCount {
            return lhs.clusteredSampleCount < rhs.clusteredSampleCount
        }
        if lhs.validSampleCount != rhs.validSampleCount {
            return lhs.validSampleCount < rhs.validSampleCount
        }

        let lhsDeviation = lhs.diagnostics.maxDeviationFrames ?? Int.max
        let rhsDeviation = rhs.diagnostics.maxDeviationFrames ?? Int.max
        if lhsDeviation != rhsDeviation {
            return lhsDeviation > rhsDeviation
        }

        let lhsDrift = lhs.diagnostics.driftFramesPerMinute ?? .greatestFiniteMagnitude
        let rhsDrift = rhs.diagnostics.driftFramesPerMinute ?? .greatestFiniteMagnitude
        if abs(lhsDrift - rhsDrift) > 0.001 {
            return lhsDrift > rhsDrift
        }

        // Prefer 24 in exact ties; it is the most common camera TC base for this workflow.
        return lhs.sourceFrameRate > rhs.sourceFrameRate
    }

    nonisolated private static func consistencyStatus(
        videoFrameRate: Double,
        sourceFrameRate: Int,
        validSampleCount: Int,
        invalidSampleCount: Int,
        clusteredSampleCount: Int,
        maxDeviationFrames: Int?,
        driftFramesPerMinute: Double?
    ) -> TimecodeConsistencyStatus {
        guard validSampleCount > 0, clusteredSampleCount > 0 else {
            return .highRisk
        }

        if invalidSampleCount > validSampleCount {
            return .highRisk
        }

        if (maxDeviationFrames ?? 0) > 2 || (driftFramesPerMinute ?? 0) > 1.0 {
            return .driftSuspected
        }

        let frameRatesMatch = abs(videoFrameRate - Double(sourceFrameRate)) <= 0.05
        return frameRatesMatch ? .consistent : .frameRateMismatchStable
    }

    nonisolated private static func diagnosticNotes(
        setting: SourceTimecodeFrameRateSetting,
        fps: Int,
        samples: [OCRSample],
        validSampleCount: Int,
        invalidSampleCount: Int,
        maxDeviationFrames: Int?,
        driftFramesPerMinute: Double?,
        status: TimecodeConsistencyStatus
    ) -> [String] {
        var notes: [String] = []

        if validSampleCount == 1 {
            notes.append("时间码样本只有 1 个，无法判断长片漂移")
        }
        if setting != .automatic, invalidSampleCount > 0 {
            notes.append("当前源 TC 帧率可能不匹配，部分时间码帧号超出范围")
        }
        if status == .driftSuspected {
            let driftText = driftFramesPerMinute.map { String(format: "%.1f", $0) } ?? "未知"
            notes.append("多点时间码疑似漂移：最大偏差 \(maxDeviationFrames ?? 0) 帧，约 \(driftText) 帧/分钟")
        }
        if status == .frameRateMismatchStable {
            notes.append("视频帧率与源 TC 帧率不一致，长片回套需复核")
        }
        if status == .highRisk, validSampleCount == 0, !samples.isEmpty {
            notes.append("未能用 \(fps)fps 解析稳定时间码")
        }

        return notes
    }

    nonisolated private static func driftFramesPerMinute(from readings: [TimecodeReading]) -> Double? {
        let sortedReadings = readings.sorted { $0.sample.actualSeconds < $1.sample.actualSeconds }
        guard let first = sortedReadings.first,
              let last = sortedReadings.last,
              last.sample.actualSeconds > first.sample.actualSeconds else {
            return nil
        }

        let minutes = (last.sample.actualSeconds - first.sample.actualSeconds) / 60.0
        guard minutes > 0 else {
            return nil
        }

        return abs(Double(last.startFrame - first.startFrame)) / minutes
    }

    nonisolated private static func annotateSamples(
        _ samples: [OCRSample],
        readings: [TimecodeReading],
        bestStartFrame: Int?
    ) -> [OCRSample] {
        let readingBySampleID = Dictionary(uniqueKeysWithValues: readings.map { ($0.sample.id, $0) })

        return samples.map { sample in
            guard sample.region.kind == .timecode else {
                return sample
            }

            guard let reading = readingBySampleID[sample.id], let bestStartFrame else {
                return annotatedSample(sample, offset: nil, status: .invalid)
            }

            let offset = reading.startFrame - bestStartFrame
            let status: TimecodeSampleStatus
            if abs(offset) <= 1 {
                status = .clustered
            } else if abs(offset) <= 2 {
                status = .deviated
            } else {
                status = .jump
            }

            return annotatedSample(sample, offset: offset, status: status)
        }
    }

    nonisolated private static func annotateInvalidTimecodeSamples(_ samples: [OCRSample]) -> [OCRSample] {
        samples.map { sample in
            sample.region.kind == .timecode
                ? annotatedSample(sample, offset: nil, status: .invalid)
                : sample
        }
    }

    nonisolated private static func annotatedSample(
        _ sample: OCRSample,
        offset: Int?,
        status: TimecodeSampleStatus
    ) -> OCRSample {
        OCRSample(
            id: sample.id,
            region: sample.region,
            requestedSeconds: sample.requestedSeconds,
            actualSeconds: sample.actualSeconds,
            rawText: sample.rawText,
            confidence: sample.confidence,
            timecodeFrameOffset: offset,
            timecodeSampleStatus: status
        )
    }

    nonisolated private static func mostCommon(_ values: [String]) -> String? {
        let grouped = Dictionary(grouping: values, by: { $0 })
        return grouped
            .max {
                if $0.value.count == $1.value.count {
                    return $0.key.count < $1.key.count
                }
                return $0.value.count < $1.value.count
            }?
            .key
    }

    nonisolated private static func bestFrameCluster(_ frames: [Int]) -> (frame: Int, count: Int)? {
        guard !frames.isEmpty else {
            return nil
        }

        return frames
            .map { candidate in
                let neighbors = frames.filter { abs($0 - candidate) <= 1 }
                let average = Int(round(Double(neighbors.reduce(0, +)) / Double(neighbors.count)))
                return (frame: average, count: neighbors.count)
            }
            .max { $0.count < $1.count }
    }

    nonisolated private static func score(hasValue: Bool, candidateCount: Int) -> Double {
        guard hasValue else {
            return 0
        }
        return min(1, 0.55 + Double(candidateCount) * 0.15)
    }
}

private enum OCRFieldParser {
    nonisolated static func clipName(from rawText: String) -> String? {
        let upper = rawText
            .uppercased()
            .replacingOccurrences(of: "\n", with: " ")

        if let separated = firstMatch(
            in: upper,
            pattern: #"[A-Z]\d{3}[_-][A-Z0-9]+(?:[_-][A-Z0-9]+)+"#
        ) {
            return separated.replacingOccurrences(of: "-", with: "_")
        }

        if let spaced = firstMatch(
            in: upper,
            pattern: #"\b[A-Z]\d{3}\s+[A-Z]\d{3}\s+[A-Z0-9]{4,}\b"#
        ) {
            return normalizeClipTokens(spaced.split(whereSeparator: \.isWhitespace).map(String.init))
        }

        let compact = upper.filter { $0.isLetter || $0.isNumber }
        if let compactMatch = firstMatch(
            in: String(compact),
            pattern: #"[A-Z]\d{3}[A-Z]\d{3}[A-Z0-9]{4,}"#
        ), compactMatch.count > 8 {
            let first = compactMatch.prefix(4)
            let middleStart = compactMatch.index(compactMatch.startIndex, offsetBy: 4)
            let middleEnd = compactMatch.index(compactMatch.startIndex, offsetBy: 8)
            let middle = compactMatch[middleStart..<middleEnd]
            let tail = compactMatch[middleEnd...]
            return "\(first)_\(middle)_\(tail)"
        }

        let looseTokens = upper
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for index in looseTokens.indices.dropLast(2) {
            let window = Array(looseTokens[index...(index + 2)])
            if let normalized = normalizeClipTokens(window) {
                return normalized
            }
        }

        return nil
    }

    nonisolated static func rollFromClipName(_ clipName: String) -> String? {
        if let arriRoll = normalizedARRIRollToken(clipName) {
            return arriRoll
        }

        guard let firstComponent = clipName.split(separator: "_").first else {
            return nil
        }

        let token = String(firstComponent)
        return normalizedRollToken(token)
    }

    nonisolated static func roll(from rawText: String) -> String? {
        let upper = rawText.uppercased()
        if let arriRoll = firstMatch(
            in: upper,
            pattern: #"\b[A-Z]_\d{4}(?:_[A-Z0-9]{2,})?\b"#
        ).flatMap(normalizedARRIRollToken) {
            return arriRoll
        }

        let tokens = upper
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for index in tokens.indices where tokens[index] == "ROLL" || tokens[index] == "REEL" {
            guard let nextIndex = tokens.index(index, offsetBy: 1, limitedBy: tokens.endIndex),
                  nextIndex < tokens.endIndex else {
                return nil
            }
            if let arriRoll = normalizedARRIRollTokens(Array(tokens[nextIndex...].prefix(3))) {
                return arriRoll
            }
            return normalizedRollToken(tokens[nextIndex])
        }

        let compact = upper.filter { $0.isLetter || $0.isNumber }
        for label in ["ROLL", "REEL"] {
            if let labelRange = compact.range(of: label) {
                let tokenStart = labelRange.upperBound
                guard let tokenEnd = compact.index(tokenStart, offsetBy: 4, limitedBy: compact.endIndex) else {
                    return nil
                }
                return normalizedRollToken(String(compact[tokenStart..<tokenEnd]))
            }
        }

        for token in tokens {
            if let normalized = normalizedRollToken(token) {
                return normalized
            }
        }

        for index in tokens.indices.dropLast() {
            if let arriRoll = normalizedARRIRollTokens(Array(tokens[index...].prefix(3))) {
                return arriRoll
            }
        }

        return nil
    }

    nonisolated static func timecode(from rawText: String, fps: Int) -> Timecode? {
        let normalized = rawText
            .uppercased()
            .replacingOccurrences(of: "O", with: "0")
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "S", with: "5")

        guard let match = firstMatch(
            in: normalized,
            pattern: #"\b([0-2]\d):([0-5]\d):([0-5]\d)[:;]([0-9]{2})\b"#
        ) else {
            return nil
        }

        let parts = match
            .replacingOccurrences(of: ";", with: ":")
            .split(separator: ":")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard parts.count == 4 else {
            return nil
        }

        guard (0...23).contains(parts[0]) else {
            return nil
        }

        let frame = parts[3]
        guard (0..<fps).contains(frame) else {
            return nil
        }

        return Timecode(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: frame, fps: fps)
    }

    nonisolated private static func normalizedRollToken(_ token: String) -> String? {
        let upper = token.uppercased()
        guard upper.count == 4,
              let first = upper.first,
              first.isLetter,
              first != "O",
              first != "I",
              first != "L",
              first != "R" else {
            return nil
        }

        let digits = upper.dropFirst().map { character -> Character in
            switch character {
            case "O":
                "0"
            case "I", "L":
                "1"
            case "S":
                "5"
            case "B":
                "8"
            default:
                character
            }
        }

        guard digits.allSatisfy(\.isNumber) else {
            return nil
        }

        return "\(first)\(String(digits))"
    }

    nonisolated private static func normalizedARRIRollToken(_ token: String) -> String? {
        let components = token
            .uppercased()
            .components(separatedBy: "_")
            .filter { !$0.isEmpty }
        return normalizedARRIRollTokens(components)
    }

    nonisolated private static func normalizedARRIRollTokens(_ tokens: [String]) -> String? {
        guard tokens.count >= 2,
              tokens[0].count == 1,
              let camera = tokens[0].first,
              camera.isLetter else {
            return nil
        }

        let rollNumber = tokens[1].map { character -> Character in
            switch character {
            case "O":
                "0"
            case "I", "L":
                "1"
            case "S":
                "5"
            case "B":
                "8"
            default:
                character
            }
        }
        guard rollNumber.count == 4, rollNumber.allSatisfy(\.isNumber) else {
            return nil
        }

        guard let suffix = tokens.dropFirst(2).first else {
            return "\(camera)_\(String(rollNumber))"
        }

        let normalizedSuffix = suffix.uppercased().filter { $0.isLetter || $0.isNumber }
        guard normalizedSuffix.count >= 2 else {
            return "\(camera)_\(String(rollNumber))"
        }

        return "\(camera)_\(String(rollNumber))_\(normalizedSuffix)"
    }

    nonisolated private static func normalizeClipTokens(_ tokens: [String]) -> String? {
        guard tokens.count >= 3,
              let first = normalizedRollToken(tokens[0]),
              let second = normalizedRollToken(tokens[1]) else {
            return nil
        }

        let tail = tokens.dropFirst(2)
            .joined(separator: "_")
            .map { character -> Character in
                switch character {
                case "O":
                    "0"
                default:
                    character
                }
            }

        guard tail.count >= 4 else {
            return nil
        }

        return "\(first)_\(second)_\(String(tail))"
    }

    nonisolated private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }

        return String(text[matchRange])
    }
}
