// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

enum OCRFieldKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case clipName
    case roll
    case timecode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clipName:
            "文件名"
        case .roll:
            "卷号"
        case .timecode:
            "时间码"
        }
    }
}

struct OCRRegion: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    let kind: OCRFieldKind
    var normalizedRect: CGRect

    static let qtakeLowerLeftPreset: [OCRRegion] = [
        OCRRegion(
            id: "clip-name",
            label: "文件名",
            kind: .clipName,
            normalizedRect: CGRect(x: 0.035, y: 0.690, width: 0.330, height: 0.085)
        ),
        OCRRegion(
            id: "roll",
            label: "卷号",
            kind: .roll,
            normalizedRect: CGRect(x: 0.035, y: 0.758, width: 0.390, height: 0.055)
        ),
        OCRRegion(
            id: "timecode",
            label: "时间码",
            kind: .timecode,
            normalizedRect: CGRect(x: 0.035, y: 0.810, width: 0.260, height: 0.080)
        )
    ]
}

struct SampleVideo: Identifiable {
    let fileName: String
    let displayName: String
    let regions: [OCRRegion]?

    var id: String { fileName }

    var resourceName: String {
        String(fileName.split(separator: ".").dropLast().joined(separator: "."))
    }

    var resourceExtension: String {
        String(fileName.split(separator: ".").last ?? "")
    }

    init(fileName: String, displayName: String, regions: [OCRRegion]? = nil) {
        self.fileName = fileName
        self.displayName = displayName
        self.regions = regions
    }
}

struct OCRSample: Identifiable, Sendable {
    let id: UUID
    let region: OCRRegion
    let requestedSeconds: Double
    let actualSeconds: Double
    let rawText: String
    let confidence: Double
    let timecodeFrameOffset: Int?
    let timecodeSampleStatus: TimecodeSampleStatus

    nonisolated init(
        id: UUID = UUID(),
        region: OCRRegion,
        requestedSeconds: Double,
        actualSeconds: Double,
        rawText: String,
        confidence: Double,
        timecodeFrameOffset: Int? = nil,
        timecodeSampleStatus: TimecodeSampleStatus = .notApplicable
    ) {
        self.id = id
        self.region = region
        self.requestedSeconds = requestedSeconds
        self.actualSeconds = actualSeconds
        self.rawText = rawText
        self.confidence = confidence
        self.timecodeFrameOffset = timecodeFrameOffset
        self.timecodeSampleStatus = timecodeSampleStatus
    }
}

struct Timecode: Equatable, Comparable, CustomStringConvertible, Sendable {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let fps: Int
    let playbackFrameRate: Double
    let isDropFrame: Bool

    nonisolated init(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        fps: Int,
        playbackFrameRate: Double? = nil,
        isDropFrame: Bool = false
    ) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.fps = fps
        self.playbackFrameRate = playbackFrameRate ?? Double(fps)
        self.isDropFrame = isDropFrame
    }

    nonisolated var totalFrames: Int {
        if isDropFrame, fps == 30 {
            let totalMinutes = hours * 60 + minutes
            let nominalFrames = (((hours * 60 + minutes) * 60 + seconds) * fps) + frames
            let droppedFrames = 2 * (totalMinutes - totalMinutes / 10)
            return nominalFrames - droppedFrames
        }

        return (((hours * 60 + minutes) * 60 + seconds) * fps) + frames
    }

    nonisolated var description: String {
        let separator = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, separator, frames)
    }

    nonisolated static func == (lhs: Timecode, rhs: Timecode) -> Bool {
        lhs.hours == rhs.hours
            && lhs.minutes == rhs.minutes
            && lhs.seconds == rhs.seconds
            && lhs.frames == rhs.frames
            && lhs.fps == rhs.fps
            && abs(lhs.playbackFrameRate - rhs.playbackFrameRate) < 0.0001
            && lhs.isDropFrame == rhs.isDropFrame
    }

    nonisolated static func < (lhs: Timecode, rhs: Timecode) -> Bool {
        lhs.totalFrames < rhs.totalFrames
    }

    nonisolated static func from(
        totalFrames rawFrames: Int,
        fps: Int,
        playbackFrameRate: Double? = nil,
        isDropFrame: Bool = false
    ) -> Timecode {
        if isDropFrame, fps == 30 {
            return dropFrameTimecode(
                from: rawFrames,
                fps: fps,
                playbackFrameRate: playbackFrameRate ?? SourceTimecodeFrameRateSetting.fps2997DF.playbackFrameRate
            )
        }

        let framesPerDay = fps * 60 * 60 * 24
        let totalFrames = ((rawFrames % framesPerDay) + framesPerDay) % framesPerDay
        let totalSeconds = totalFrames / fps
        let frames = totalFrames % fps
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = (totalSeconds / 3600) % 24
        return Timecode(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: false
        )
    }

    nonisolated static func parse(
        _ value: String,
        fps: Int,
        playbackFrameRate: Double? = nil,
        isDropFrame: Bool = false
    ) -> Timecode? {
        guard fps > 0 else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isDropFrame || trimmed.contains(";") else {
            return nil
        }

        let normalized = trimmed.replacingOccurrences(of: ";", with: ":")
        let parts = normalized
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(Int.init)

        guard parts.count == 4,
              (0...23).contains(parts[0]),
              (0...59).contains(parts[1]),
              (0...59).contains(parts[2]),
              (0..<fps).contains(parts[3]) else {
            return nil
        }

        if isDropFrame {
            guard fps == 30, isValidDropFrameLabel(minutes: parts[1], seconds: parts[2], frames: parts[3]) else {
                return nil
            }
        }

        return Timecode(
            hours: parts[0],
            minutes: parts[1],
            seconds: parts[2],
            frames: parts[3],
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: isDropFrame
        )
    }

    nonisolated private static func dropFrameTimecode(
        from rawFrames: Int,
        fps: Int,
        playbackFrameRate: Double
    ) -> Timecode {
        let dropFrames = 2
        let framesPerHour = 107_892
        let framesPer24Hours = framesPerHour * 24
        let framesPer10Minutes = 17_982
        let framesPerMinute = 1_798
        var totalFrames = rawFrames % framesPer24Hours
        if totalFrames < 0 {
            totalFrames += framesPer24Hours
        }

        let tenMinuteChunks = totalFrames / framesPer10Minutes
        let remainingFrames = totalFrames % framesPer10Minutes
        let additionalDroppedFrames = max(0, (remainingFrames - dropFrames) / framesPerMinute)
        let nominalFrameNumber = totalFrames + dropFrames * (9 * tenMinuteChunks + additionalDroppedFrames)
        let totalSeconds = nominalFrameNumber / fps
        let frames = nominalFrameNumber % fps
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = (totalSeconds / 3600) % 24

        return Timecode(
            hours: hours,
            minutes: minutes,
            seconds: seconds,
            frames: frames,
            fps: fps,
            playbackFrameRate: playbackFrameRate,
            isDropFrame: true
        )
    }

    nonisolated private static func isValidDropFrameLabel(minutes: Int, seconds: Int, frames: Int) -> Bool {
        if minutes % 10 == 0 {
            return true
        }
        return !(seconds == 0 && frames < 2)
    }
}

enum SourceTimecodeFrameRateSetting: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case automatic
    case fps23976
    case fps24
    case fps25
    case fps2997NDF
    case fps2997DF
    case fps30

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .automatic:
            "自动"
        case .fps23976:
            "23.976"
        case .fps24:
            "24"
        case .fps25:
            "25"
        case .fps2997NDF:
            "29.97 NDF"
        case .fps2997DF:
            "29.97 DF"
        case .fps30:
            "30"
        }
    }

    nonisolated var fps: Int? {
        switch self {
        case .automatic:
            nil
        case .fps23976:
            24
        case .fps24:
            24
        case .fps25:
            25
        case .fps2997NDF, .fps2997DF:
            30
        case .fps30:
            30
        }
    }

    nonisolated var playbackFrameRate: Double {
        switch self {
        case .fps23976:
            24_000.0 / 1_001.0
        case .fps2997NDF, .fps2997DF:
            30_000.0 / 1_001.0
        case .automatic, .fps24, .fps25, .fps30:
            Double(fps ?? 24)
        }
    }

    nonisolated var isDropFrame: Bool {
        self == .fps2997DF
    }

    nonisolated var candidateFrameRates: [Int] {
        fps.map { [$0] } ?? [24, 25, 30]
    }
}

enum TimecodeBurnOutputMode: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case sourceFile
    case copyToFolder

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .sourceFile:
            "烧录到源文件"
        case .copyToFolder:
            "复制到新文件夹并烧录"
        }
    }

    nonisolated var description: String {
        switch self {
        case .sourceFile:
            "直接修改列表内原始 MOV/QuickTime 文件；没有 TMCD 轨道的文件会被拒绝。"
        case .copyToFolder:
            "源文件不变，输出到新文件夹；没有 TMCD 轨道时会尝试重新封装为带 TMCD 的 MOV。"
        }
    }
}

struct ProjectOutputSettings: Codable, Equatable, Sendable {
    var isTimecodeBurnEnabled: Bool
    var timecodeBurnOutputMode: TimecodeBurnOutputMode
    var isFileRenameEnabled: Bool
    var exportsCompanionCSVForRenamedFiles: Bool
    var showsTimecodeDiagnosticsDetails: Bool
    var renamePrefix: String
    var renameSuffix: String

    nonisolated init(
        isTimecodeBurnEnabled: Bool = false,
        timecodeBurnOutputMode: TimecodeBurnOutputMode = .sourceFile,
        isFileRenameEnabled: Bool = false,
        exportsCompanionCSVForRenamedFiles: Bool = false,
        showsTimecodeDiagnosticsDetails: Bool = false,
        renamePrefix: String = "",
        renameSuffix: String = ""
    ) {
        self.isTimecodeBurnEnabled = isTimecodeBurnEnabled
        self.timecodeBurnOutputMode = timecodeBurnOutputMode
        self.isFileRenameEnabled = isFileRenameEnabled
        self.exportsCompanionCSVForRenamedFiles = exportsCompanionCSVForRenamedFiles
        self.showsTimecodeDiagnosticsDetails = showsTimecodeDiagnosticsDetails
        self.renamePrefix = renamePrefix
        self.renameSuffix = renameSuffix
    }

    enum CodingKeys: String, CodingKey {
        case isTimecodeBurnEnabled
        case timecodeBurnOutputMode
        case isFileRenameEnabled
        case exportsCompanionCSVForRenamedFiles
        case showsTimecodeDiagnosticsDetails
        case renamePrefix
        case renameSuffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isTimecodeBurnEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTimecodeBurnEnabled) ?? false
        timecodeBurnOutputMode = try container.decodeIfPresent(TimecodeBurnOutputMode.self, forKey: .timecodeBurnOutputMode) ?? .sourceFile
        isFileRenameEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFileRenameEnabled) ?? false
        exportsCompanionCSVForRenamedFiles = try container.decodeIfPresent(Bool.self, forKey: .exportsCompanionCSVForRenamedFiles) ?? false
        showsTimecodeDiagnosticsDetails = try container.decodeIfPresent(Bool.self, forKey: .showsTimecodeDiagnosticsDetails) ?? false
        renamePrefix = try container.decodeIfPresent(String.self, forKey: .renamePrefix) ?? ""
        renameSuffix = try container.decodeIfPresent(String.self, forKey: .renameSuffix) ?? ""
    }
}

enum TimecodeSampleStatus: String, Sendable {
    case notApplicable
    case clustered
    case deviated
    case jump
    case invalid

    nonisolated var title: String {
        switch self {
        case .notApplicable:
            ""
        case .clustered:
            "稳定"
        case .deviated:
            "偏离"
        case .jump:
            "跳变"
        case .invalid:
            "无效"
        }
    }
}

enum TimecodeConsistencyStatus: String, Sendable {
    case notChecked
    case consistent
    case frameRateMismatchStable
    case driftSuspected
    case highRisk

    nonisolated var title: String {
        switch self {
        case .notChecked:
            "未检测"
        case .consistent:
            "一致"
        case .frameRateMismatchStable:
            "帧率不一致但 TC 稳定"
        case .driftSuspected:
            "疑似漂移"
        case .highRisk:
            "高风险"
        }
    }
}

struct TimecodeDiagnostics: Sendable {
    let setting: SourceTimecodeFrameRateSetting
    let videoFrameRate: Double
    let sourceTimecodeFrameRate: Int?
    let validSampleCount: Int
    let invalidSampleCount: Int
    let maxDeviationFrames: Int?
    let driftFramesPerMinute: Double?
    let status: TimecodeConsistencyStatus
    let notes: [String]

    nonisolated var sourceFrameRateDisplay: String {
        guard let sourceTimecodeFrameRate else {
            return setting == .automatic ? "自动（未推断）" : setting.title
        }

        if setting == .automatic {
            return "自动推断 \(sourceTimecodeFrameRate)"
        }
        return setting.title
    }

    nonisolated var driftDisplay: String {
        guard let maxDeviationFrames else {
            return "未检测"
        }

        let driftText = driftFramesPerMinute.map {
            String(format: "，约 %.1f 帧/分钟", $0)
        } ?? ""
        return "最大偏差 \(maxDeviationFrames) 帧\(driftText)"
    }
}

struct QuickTimeTimecodeMetadata: Equatable, Sendable {
    let firstFrame: String?
    let lastFrame: String?
    let frameRate: Double?
    let frameQuanta: Int?
    let format: String?

    nonisolated var roundedFrameRate: Int? {
        frameQuanta ?? frameRate.map { max(1, Int(round($0))) }
    }

    nonisolated var displayText: String {
        let rateText = roundedFrameRate.map { "\($0) fps" } ?? "未知帧率"
        let firstText = firstFrame ?? "--:--:--:--"
        return "有，\(rateText)，\(firstText)"
    }
}

struct ManualMetadataOverrides: Equatable, Sendable {
    var clipName = ""
    var roll = ""
    var cameraID = ""
    var startTimecode = ""

    nonisolated init(
        clipName: String = "",
        roll: String = "",
        cameraID: String = "",
        startTimecode: String = ""
    ) {
        self.clipName = clipName
        self.roll = roll
        self.cameraID = cameraID
        self.startTimecode = startTimecode
    }

    nonisolated var hasAnyOverride: Bool {
        trimmedClipName != nil
            || trimmedRoll != nil
            || trimmedCameraID != nil
            || trimmedStartTimecode != nil
    }

    nonisolated var trimmedClipName: String? {
        Self.trimmed(clipName)
    }

    nonisolated var trimmedRoll: String? {
        Self.trimmed(roll)
    }

    nonisolated var trimmedCameraID: String? {
        Self.trimmed(cameraID)?.uppercased()
    }

    nonisolated var trimmedStartTimecode: String? {
        Self.trimmed(startTimecode)
    }

    nonisolated static func cameraID(from roll: String?) -> String? {
        guard let roll = trimmed(roll)?.uppercased(),
              let first = roll.first,
              first.isLetter else {
            return nil
        }

        let characters = Array(roll)
        if characters.count >= 2, characters[1] == "_" {
            return "\(first)_"
        }

        return String(first)
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct ClipOCRResult: Sendable {
    let videoName: String
    let fps: Int
    let videoFrameRate: Double
    let sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting
    let duration: Double
    let clipName: String?
    let roll: String?
    let startTimecode: Timecode?
    let confidence: Double
    let samples: [OCRSample]
    let timecodeDiagnostics: TimecodeDiagnostics?
    let notes: [String]

    nonisolated var cameraID: String? {
        ManualMetadataOverrides.cameraID(from: roll)
    }

    nonisolated var statusTitle: String {
        if confidence >= 0.82 {
            "可信"
        } else if confidence >= 0.45 {
            "需复核"
        } else {
            "失败"
        }
    }
}

struct ClipExportMetadata: Sendable {
    let duration: Double?
    let clipName: String?
    let roll: String?
    let cameraID: String?
    let startTimecode: Timecode?

    nonisolated init(
        duration: Double?,
        clipName: String?,
        roll: String?,
        cameraID: String?,
        startTimecode: Timecode?
    ) {
        self.duration = duration
        self.clipName = clipName
        self.roll = roll
        self.cameraID = cameraID
        self.startTimecode = startTimecode
    }

    nonisolated init(result: ClipOCRResult) {
        self.duration = result.duration
        self.clipName = result.clipName
        self.roll = result.roll
        self.cameraID = result.cameraID
        self.startTimecode = result.startTimecode
    }
}

enum MediaAnalysisStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case analyzing
    case trusted
    case needsReview
    case failed

    var title: String {
        switch self {
        case .pending:
            "待识别"
        case .analyzing:
            "识别中"
        case .trusted:
            "可信"
        case .needsReview:
            "需复核"
        case .failed:
            "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .pending:
            "clock"
        case .analyzing:
            "text.viewfinder"
        case .trusted:
            "checkmark.circle"
        case .needsReview:
            "exclamationmark.triangle"
        case .failed:
            "xmark.octagon"
        }
    }

    static func status(for result: ClipOCRResult) -> MediaAnalysisStatus {
        if result.timecodeDiagnostics?.status == .highRisk {
            return .needsReview
        }
        if result.timecodeDiagnostics?.status == .driftSuspected {
            return .needsReview
        }
        if result.confidence >= 0.82 {
            return .trusted
        }
        if result.confidence >= 0.45 {
            return .needsReview
        }
        return .failed
    }
}

struct MediaQueueItem: Identifiable {
    let id: UUID
    let url: URL
    var analysisStatus: MediaAnalysisStatus
    var result: ClipOCRResult?
    var errorMessage: String?
    var sourceMetadataFields: [MetadataField]
    var sourceMetadataStatus: String
    var isLoadingSourceMetadata: Bool
    var sourceTimecodeMetadata: QuickTimeTimecodeMetadata?
    var manualMetadata: ManualMetadataOverrides

    nonisolated init(
        id: UUID = UUID(),
        url: URL,
        analysisStatus: MediaAnalysisStatus = .pending,
        result: ClipOCRResult? = nil,
        errorMessage: String? = nil,
        sourceMetadataFields: [MetadataField] = [],
        sourceMetadataStatus: String = "未读取",
        isLoadingSourceMetadata: Bool = false,
        sourceTimecodeMetadata: QuickTimeTimecodeMetadata? = nil,
        manualMetadata: ManualMetadataOverrides = ManualMetadataOverrides()
    ) {
        self.id = id
        self.url = url
        self.analysisStatus = analysisStatus
        self.result = result
        self.errorMessage = errorMessage
        self.sourceMetadataFields = sourceMetadataFields
        self.sourceMetadataStatus = sourceMetadataStatus
        self.isLoadingSourceMetadata = isLoadingSourceMetadata
        self.sourceTimecodeMetadata = sourceTimecodeMetadata
        self.manualMetadata = manualMetadata
    }

    var displayName: String {
        url.lastPathComponent
    }

    var directoryPath: String {
        url.deletingLastPathComponent().path
    }

    var canExportDaVinciMetadata: Bool {
        guard let result, analysisStatus != .failed else {
            return false
        }
        return DaVinciMetadataCSVExporter.hasExportableMetadata(result)
    }
}

struct ROIPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var regions: [ROIPresetRegion]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        regions: [OCRRegion],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.regions = regions.map(ROIPresetRegion.init(region:))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    nonisolated var ocrRegions: [OCRRegion] {
        regions.map(\.ocrRegion)
    }
}

struct ROIPresetRegion: Codable, Equatable, Sendable {
    var id: String
    var label: String
    var kind: OCRFieldKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    nonisolated init(region: OCRRegion) {
        id = region.id
        label = region.label
        kind = region.kind
        x = Double(region.normalizedRect.minX)
        y = Double(region.normalizedRect.minY)
        width = Double(region.normalizedRect.width)
        height = Double(region.normalizedRect.height)
    }

    nonisolated var ocrRegion: OCRRegion {
        OCRRegion(
            id: id,
            label: label,
            kind: kind,
            normalizedRect: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        )
    }
}

struct DaVinciMetadataCSVRow {
    let videoURL: URL
    let metadata: ClipExportMetadata

    nonisolated init(videoURL: URL, result: ClipOCRResult) {
        self.videoURL = videoURL
        self.metadata = ClipExportMetadata(result: result)
    }

    nonisolated init(videoURL: URL, metadata: ClipExportMetadata) {
        self.videoURL = videoURL
        self.metadata = metadata
    }
}

struct DaVinciMetadataCSVExporter {
    nonisolated static let batchHeaders = [
        "File Name",
        "Duration TC",
        "Reel Number",
        "Camera #",
        "Start TC",
        "End TC",
        "Start Frame",
        "End Frame",
        "Frames"
    ]

    nonisolated static func hasExportableMetadata(_ result: ClipOCRResult) -> Bool {
        hasExportableMetadata(ClipExportMetadata(result: result))
    }

    nonisolated static func hasExportableMetadata(_ metadata: ClipExportMetadata) -> Bool {
        !metadataFields(for: metadata).isEmpty
    }

    nonisolated static func exportFields(videoURL: URL, result: ClipOCRResult) -> [(header: String, value: String)] {
        exportFields(videoURL: videoURL, metadata: ClipExportMetadata(result: result))
    }

    nonisolated static func exportFields(videoURL: URL, metadata: ClipExportMetadata) -> [(header: String, value: String)] {
        let values = metadataValues(videoURL: videoURL, metadata: metadata)
        return batchHeaders.compactMap { header in
            guard let value = values[header], !value.isEmpty else {
                return nil
            }
            return (header, value)
        }
    }

    nonisolated static func makeData(videoURL: URL, result: ClipOCRResult) throws -> Data {
        try makeData(rows: [DaVinciMetadataCSVRow(videoURL: videoURL, result: result)])
    }

    nonisolated static func makeData(rows: [DaVinciMetadataCSVRow]) throws -> Data {
        guard !rows.isEmpty, rows.contains(where: { hasExportableMetadata($0.metadata) }) else {
            throw ExportError.noMetadata
        }

        // Keep File Name for Resolve matching, but avoid Clip Directory to prevent relinking media.
        let csvRows = [batchHeaders] + rows.map { row in
            let values = metadataValues(videoURL: row.videoURL, metadata: row.metadata)
            return batchHeaders.map { values[$0] ?? "" }
        }

        let csvText = csvRows
            .map { row in row.map(escape).joined(separator: ",") }
            .joined(separator: "\n") + "\n"

        guard let csvBody = csvText.data(using: .utf16LittleEndian) else {
            throw ExportError.encodingFailed
        }

        var data = Data([0xFF, 0xFE])
        data.append(csvBody)
        return data
    }

    nonisolated private static func metadataFields(for result: ClipOCRResult) -> [(header: String, value: String)] {
        metadataFields(for: ClipExportMetadata(result: result))
    }

    nonisolated private static func metadataFields(for metadata: ClipExportMetadata) -> [(header: String, value: String)] {
        metadataFields(videoURL: nil, metadata: metadata)
            .filter { $0.header != "File Name" }
    }

    nonisolated private static func metadataFields(videoURL: URL?, metadata: ClipExportMetadata) -> [(header: String, value: String)] {
        var fields: [(header: String, value: String)] = []

        if let videoURL {
            fields.append(("File Name", videoURL.lastPathComponent))
        }

        if let startTimecode = metadata.startTimecode {
            if let duration = metadata.duration {
                let frameCount = frameCount(duration: duration, playbackFrameRate: startTimecode.playbackFrameRate)
                let endFrame = max(frameCount - 1, 0)
                let endTimecode = Timecode.from(
                    totalFrames: startTimecode.totalFrames + endFrame,
                    fps: startTimecode.fps,
                    playbackFrameRate: startTimecode.playbackFrameRate,
                    isDropFrame: startTimecode.isDropFrame
                )

                fields.append(
                    (
                        "Duration TC",
                        Timecode.from(
                            totalFrames: frameCount,
                            fps: startTimecode.fps,
                            playbackFrameRate: startTimecode.playbackFrameRate,
                            isDropFrame: startTimecode.isDropFrame
                        ).description
                    )
                )
                fields.append(("End TC", endTimecode.description))
                fields.append(("End Frame", "\(endFrame)"))
                fields.append(("Frames", "\(frameCount)"))
            }
            fields.append(("Start TC", startTimecode.description))
            fields.append(("Start Frame", "0"))
        }

        if let roll = trimmed(metadata.roll) {
            let insertionIndex = fields.firstIndex(where: { $0.header == "Start TC" }) ?? fields.count
            fields.insert(("Reel Number", roll), at: insertionIndex)
        }

        if let cameraID = trimmed(metadata.cameraID) {
            let insertionIndex = fields.firstIndex(where: { $0.header == "Start TC" }) ?? fields.count
            fields.insert(("Camera #", cameraID), at: insertionIndex)
        }

        return fields
    }

    nonisolated private static func metadataValues(videoURL: URL, result: ClipOCRResult) -> [String: String] {
        metadataValues(videoURL: videoURL, metadata: ClipExportMetadata(result: result))
    }

    nonisolated private static func metadataValues(videoURL: URL, metadata: ClipExportMetadata) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: metadataFields(videoURL: videoURL, metadata: metadata)
                .map { ($0.header, $0.value) }
        )
    }

    nonisolated private static func frameCount(duration: Double, playbackFrameRate: Double) -> Int {
        guard duration.isFinite, playbackFrameRate > 0 else {
            return 1
        }

        return max(1, Int((duration * playbackFrameRate).rounded()))
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    nonisolated private static func escape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") || escaped.contains("\r") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    enum ExportError: LocalizedError {
        case noMetadata
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noMetadata:
                "没有可导出的 DaVinci Resolve CSV 元数据字段"
            case .encodingFailed:
                "CSV 文本编码失败"
            }
        }
    }
}

struct PremiereProXMLRow {
    let videoURL: URL
    let metadata: ClipExportMetadata

    nonisolated init(videoURL: URL, metadata: ClipExportMetadata) {
        self.videoURL = videoURL
        self.metadata = metadata
    }
}

struct PremiereProXMLExporter {
    nonisolated static func hasExportableMetadata(_ metadata: ClipExportMetadata) -> Bool {
        metadata.startTimecode != nil
            || trimmed(metadata.clipName) != nil
            || trimmed(metadata.roll) != nil
            || trimmed(metadata.cameraID) != nil
    }

    nonisolated static func makeData(rows: [PremiereProXMLRow]) throws -> Data {
        let rows = rows.filter { hasExportableMetadata($0.metadata) }
        guard !rows.isEmpty else {
            throw ExportError.noMetadata
        }

        let binName = commonRollName(rows: rows) ?? "Aquarius_Metadata"
        let clips = rows.enumerated().map { offset, row in
            clipXML(row: row, index: offset)
        }.joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
          <bin>
            <name>\(escapeText(binName))</name>
            <bin>
              <name>Video Clips</name>
              <children>
        \(clips)
              </children>
            </bin>
          </bin>
        </xmeml>
        """

        guard let data = xml.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    nonisolated private static func clipXML(row: PremiereProXMLRow, index: Int) -> String {
        let metadata = row.metadata
        let clipName = trimmed(metadata.clipName)
            ?? row.videoURL.deletingPathExtension().lastPathComponent
        let rollName = trimmed(metadata.roll)
        let cameraID = trimmed(metadata.cameraID)
        let startTimecode = metadata.startTimecode
        let durationFrames = frameCount(
            duration: metadata.duration,
            playbackFrameRate: startTimecode?.playbackFrameRate ?? Double(startTimecode?.fps ?? 25)
        )
        let rate = rateXML(for: startTimecode)
        let displayFormat = startTimecode?.isDropFrame == true ? "DF" : "NDF"
        let sourceFrame = startTimecode?.totalFrames ?? 0
        let clipID = safeXMLID(stem: clipName, index: index)
        let masterClipID = "MASTER_\(clipID)"
        let fileID = "video_file_\(clipID)"
        let reelXML = rollName.map { "\n                      <reel>\n                        <name>\(escapeText($0))</name>\n                      </reel>" } ?? ""
        let cameraNote = cameraID.map { "Camera: \(escapeText($0))" } ?? ""
        let filmDataXML = rollName.map {
            """
              <filmdata>
                <cameraroll>\(escapeText($0))</cameraroll>
                <filmslate>
                  <take/>
                  <scene/>
                </filmslate>
              </filmdata>
            """
        } ?? ""

        return """
                <clip id="\(escapeText(clipID))">
                  <uuid>\(UUID().uuidString.uppercased())</uuid>
                  <masterclipid>\(escapeText(masterClipID))</masterclipid>
                  <ismasterclip>TRUE</ismasterclip>
                  <duration>\(durationFrames)</duration>
        \(rate.indented(by: 10))
                  <name>\(escapeText(clipName))</name>
                  <media>
                    <video>
                      <track>
                        <clipitem id="\(escapeText(clipID))_ci">
                          <masterclipid>\(escapeText(masterClipID))</masterclipid>
                          <name>\(escapeText(clipName))</name>
                          <file id="\(escapeText(fileID))">
                            <name>\(escapeText(row.videoURL.lastPathComponent))</name>
                            <pathurl>\(escapeText(row.videoURL.absoluteString))</pathurl>
                            <duration>\(durationFrames)</duration>
                            <timecode>
                              <frame>\(sourceFrame)</frame>
                              <displayformat>\(displayFormat)</displayformat>
                              <source>source</source>\(reelXML)
                            </timecode>
                            <media>
                              <video>
                                <samplecharacteristics>
                                  <pixelaspectratio>Square</pixelaspectratio>
                                </samplecharacteristics>
                              </video>
                            </media>
                          </file>
                        </clipitem>
                        <enabled>TRUE</enabled>
                        <locked>FALSE</locked>
                      </track>
                    </video>
                  </media>
                  <logginginfo>
                    <description/>
                    <scene/>
                    <shottake/>
                    <lognote>\(cameraNote)</lognote>
                    <good>FALSE</good>
                  </logginginfo>
        \(filmDataXML.indented(by: 10))
                  <in>-1</in>
                  <out>-1</out>
                  <comments>
                    <mastercomment1>Exported by Aquarius</mastercomment1>
                    <mastercomment2/>
                    <mastercomment3/>
                    <mastercomment4/>
                  </comments>
                  <defaultangle/>
                </clip>
        """
    }

    nonisolated private static func rateXML(for timecode: Timecode?) -> String {
        let fps = timecode?.fps ?? 25
        let playbackFrameRate = timecode?.playbackFrameRate ?? Double(fps)
        let isNTSC = abs(playbackFrameRate - Double(fps)) > 0.0001
        return """
        <rate>
          <ntsc>\(isNTSC ? "TRUE" : "FALSE")</ntsc>
          <timebase>\(fps)</timebase>
        </rate>
        """
    }

    nonisolated private static func commonRollName(rows: [PremiereProXMLRow]) -> String? {
        let rollNames = Set(rows.compactMap { trimmed($0.metadata.roll) })
        return rollNames.count == 1 ? rollNames.first : nil
    }

    nonisolated private static func frameCount(duration: Double?, playbackFrameRate: Double) -> Int {
        guard let duration, duration.isFinite, playbackFrameRate > 0 else {
            return 1
        }

        return max(1, Int((duration * playbackFrameRate).rounded()))
    }

    nonisolated private static func safeXMLID(stem: String, index: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = stem.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let base = sanitized.isEmpty ? "clip" : sanitized
        return "\(base)_\(index + 1)"
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    nonisolated private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    enum ExportError: LocalizedError {
        case noMetadata
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noMetadata:
                "没有可导出的 Premiere Pro XML 元数据字段"
            case .encodingFailed:
                "Premiere Pro XML 文本编码失败"
            }
        }
    }
}

struct FinalCutMetadataXMLRow {
    let videoURL: URL
    let metadata: ClipExportMetadata

    nonisolated init(videoURL: URL, metadata: ClipExportMetadata) {
        self.videoURL = videoURL
        self.metadata = metadata
    }
}

struct FinalCutPro7XMLExporter {
    nonisolated static func hasExportableMetadata(_ metadata: ClipExportMetadata) -> Bool {
        metadata.startTimecode != nil
            || XMLExportSupport.trimmed(metadata.clipName) != nil
            || XMLExportSupport.trimmed(metadata.roll) != nil
            || XMLExportSupport.trimmed(metadata.cameraID) != nil
    }

    nonisolated static func makeData(rows: [FinalCutMetadataXMLRow]) throws -> Data {
        let rows = rows.filter { hasExportableMetadata($0.metadata) }
        guard !rows.isEmpty else {
            throw ExportError.noMetadata
        }

        let binName = XMLExportSupport.commonRollName(rows: rows) ?? "Aquarius_Metadata"
        let clips = rows.enumerated().map { index, row in
            clipXML(row: row, index: index)
        }.joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4">
          <bin>
            <uuid>\(UUID().uuidString.uppercased())</uuid>
            <updatebehavior>add</updatebehavior>
            <name>\(XMLExportSupport.escapeText(binName))</name>
            <children>
        \(clips)
            </children>
          </bin>
        </xmeml>
        """

        guard let data = xml.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    nonisolated private static func clipXML(row: FinalCutMetadataXMLRow, index: Int) -> String {
        let metadata = row.metadata
        let clipName = XMLExportSupport.trimmed(metadata.clipName)
            ?? row.videoURL.deletingPathExtension().lastPathComponent
        let rollName = XMLExportSupport.trimmed(metadata.roll)
        let cameraID = XMLExportSupport.trimmed(metadata.cameraID)
        let startTimecode = metadata.startTimecode
        let durationFrames = XMLExportSupport.frameCount(
            duration: metadata.duration,
            playbackFrameRate: startTimecode?.playbackFrameRate ?? Double(startTimecode?.fps ?? 25)
        )
        let rate = XMLExportSupport.xmemlRateXML(for: startTimecode)
        let timecodeRate = XMLExportSupport.xmemlRateXML(for: startTimecode).indented(by: 12)
        let displayFormat = startTimecode?.isDropFrame == true ? "DF" : "NDF"
        let sourceFrame = startTimecode?.totalFrames ?? 0
        let clipID = XMLExportSupport.safeXMLID(stem: clipName, index: index)
        let masterClipID = "MASTER_\(clipID)"
        let fileID = "video_file_\(clipID)"
        let reelXML = rollName.map {
            """

            <reel>
              <name>\(XMLExportSupport.escapeText($0))</name>
            </reel>
            """
        } ?? ""
        let cameraComment = cameraID.map { "Camera:\(XMLExportSupport.escapeText($0))" } ?? ""

        return """
              <clip id="\(XMLExportSupport.escapeText(clipID))">
                <uuid>\(UUID().uuidString.uppercased())</uuid>
                <updatebehavior>add</updatebehavior>
                <name>\(XMLExportSupport.escapeText(clipName))</name>
                <duration>\(durationFrames)</duration>
        \(rate.indented(by: 8))
                <file id="\(XMLExportSupport.escapeText(fileID))">
                  <name>\(XMLExportSupport.escapeText(row.videoURL.lastPathComponent))</name>
                  <pathurl>\(XMLExportSupport.escapeText(row.videoURL.absoluteString))</pathurl>
                  <timecode>
                    <frame>\(sourceFrame)</frame>
                    <displayformat>\(displayFormat)</displayformat>
                    <source>source</source>\(reelXML)
        \(timecodeRate)
                  </timecode>
                </file>
                <media>
                  <video>
                    <track>
                      <clipitem id="\(XMLExportSupport.escapeText(clipID))_ci"/>
                      <enabled>TRUE</enabled>
                      <locked>FALSE</locked>
                    </track>
                  </video>
                </media>
                <in>-1</in>
                <out>-1</out>
                <masterclipid>\(XMLExportSupport.escapeText(masterClipID))</masterclipid>
                <ismasterclip>TRUE</ismasterclip>
                <logginginfo>
                  <description/>
                  <scene/>
                  <shottake/>
                  <lognote/>
                  <good>FALSE</good>
                </logginginfo>
                <comments>
                  <mastercomment1>Exported by Aquarius</mastercomment1>
                  <mastercomment2>\(cameraComment)</mastercomment2>
                  <mastercomment3/>
                  <clipcommenta/>
                  <clipcommentb/>
                </comments>
                <labels>
                  <label>No Label</label>
                </labels>
                <defaultangle/>
              </clip>
        """
    }

    enum ExportError: LocalizedError {
        case noMetadata
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noMetadata:
                "没有可导出的 Final Cut Pro 7 XML 元数据字段"
            case .encodingFailed:
                "Final Cut Pro 7 XML 文本编码失败"
            }
        }
    }
}

struct FinalCutProXMLExporter {
    nonisolated static func hasExportableMetadata(_ metadata: ClipExportMetadata) -> Bool {
        FinalCutPro7XMLExporter.hasExportableMetadata(metadata)
    }

    nonisolated static func makeData(rows: [FinalCutMetadataXMLRow]) throws -> Data {
        let rows = rows.filter { hasExportableMetadata($0.metadata) }
        guard !rows.isEmpty else {
            throw ExportError.noMetadata
        }

        let eventName = XMLExportSupport.commonRollName(rows: rows) ?? "Aquarius_Metadata"
        let formats = formatXML(rows: rows)
        let assets = rows.enumerated().map { index, row in
            assetXML(row: row, index: index)
        }.joined(separator: "\n")
        let eventClips = rows.enumerated().map { index, row in
            assetClipXML(row: row, index: index, indentation: 6)
        }.joined(separator: "\n")
        let spineClips = rows.enumerated().map { index, row in
            assetClipXML(row: row, index: index, indentation: 12)
        }.joined(separator: "\n")
        let firstRow = rows[0]
        let firstTiming = timing(for: firstRow)

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.9">
          <resources>
        \(formats.indented(by: 4))
        \(assets)
          </resources>
          <library>
            <event uid="\(UUID().uuidString.uppercased())" name="\(XMLExportSupport.escapeText(eventName))">
        \(eventClips)
              <project name="\(XMLExportSupport.escapeText(eventName))">
                <sequence tcFormat="\(firstTiming.tcFormat)" audioLayout="stereo" duration="\(firstTiming.duration)" tcStart="\(firstTiming.start)" format="f1">
                  <spine>
        \(spineClips)
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>
        """

        guard let data = xml.data(using: .utf8) else {
            throw ExportError.encodingFailed
        }
        return data
    }

    nonisolated private static func formatXML(rows: [FinalCutMetadataXMLRow]) -> String {
        let timing = timing(for: rows[0])
        return """
        <format id="f1" name="FFVideoFormatRateUndefined" frameDuration="\(timing.frameDuration)"/>
        """
    }

    nonisolated private static func assetXML(row: FinalCutMetadataXMLRow, index: Int) -> String {
        let metadata = row.metadata
        let clipName = XMLExportSupport.trimmed(metadata.clipName)
            ?? row.videoURL.deletingPathExtension().lastPathComponent
        let timing = timing(for: row)
        return """
            <asset id="r\(index + 1)" name="\(XMLExportSupport.escapeText(clipName))" format="f1" hasVideo="1" duration="\(timing.duration)" start="\(timing.start)">
              <media-rep kind="original-media" src="\(XMLExportSupport.escapeText(row.videoURL.absoluteString))"/>
            </asset>
        """
    }

    nonisolated private static func assetClipXML(
        row: FinalCutMetadataXMLRow,
        index: Int,
        indentation: Int
    ) -> String {
        let metadata = row.metadata
        let clipName = XMLExportSupport.trimmed(metadata.clipName)
            ?? row.videoURL.deletingPathExtension().lastPathComponent
        let rollName = XMLExportSupport.trimmed(metadata.roll)
        let cameraID = XMLExportSupport.trimmed(metadata.cameraID)
        let timing = timing(for: row)
        let metadataXML = clipMetadataXML(rollName: rollName, cameraID: cameraID)

        return """
        <asset-clip ref="r\(index + 1)" format="f1" tcFormat="\(timing.tcFormat)" name="\(XMLExportSupport.escapeText(clipName))" start="\(timing.start)" duration="\(timing.duration)">
          <note/>
        \(metadataXML.indented(by: 2))
        </asset-clip>
        """.indented(by: indentation)
    }

    nonisolated private static func clipMetadataXML(rollName: String?, cameraID: String?) -> String {
        var fields: [String] = []
        if let rollName {
            fields.append("<md key=\"com.apple.proapps.studio.reel\" value=\"\(XMLExportSupport.escapeText(rollName))\"/>")
        }
        if let cameraID {
            fields.append("<md key=\"com.apple.proapps.mio.cameraName\" value=\"\(XMLExportSupport.escapeText(cameraID))\"/>")
        }

        guard !fields.isEmpty else {
            return "<metadata/>"
        }

        return """
        <metadata>
        \(fields.map { "  \($0)" }.joined(separator: "\n"))
        </metadata>
        """
    }

    nonisolated private static func timing(for row: FinalCutMetadataXMLRow) -> FCPXMLTiming {
        let timecode = row.metadata.startTimecode
        let fps = timecode?.fps ?? 25
        let playbackFrameRate = timecode?.playbackFrameRate ?? Double(fps)
        let durationFrames = XMLExportSupport.frameCount(
            duration: row.metadata.duration,
            playbackFrameRate: playbackFrameRate
        )
        let startFrame = timecode?.totalFrames ?? 0
        let frameDuration = frameDurationString(fps: fps, playbackFrameRate: playbackFrameRate)
        let denominator = timingDenominator(fps: fps, playbackFrameRate: playbackFrameRate)
        let numerator = timingNumerator(fps: fps, playbackFrameRate: playbackFrameRate)
        return FCPXMLTiming(
            start: "\(startFrame * numerator)/\(denominator)s",
            duration: "\(durationFrames * numerator)/\(denominator)s",
            frameDuration: frameDuration,
            tcFormat: timecode?.isDropFrame == true ? "DF" : "NDF"
        )
    }

    nonisolated private static func frameDurationString(fps: Int, playbackFrameRate: Double) -> String {
        if abs(playbackFrameRate - Double(fps)) < 0.0001 {
            return "100/\(fps * 100)s"
        }

        if fps == 24 {
            return "1001/24000s"
        }
        if fps == 30 {
            return "1001/30000s"
        }
        return "100/\(fps * 100)s"
    }

    nonisolated private static func timingNumerator(fps: Int, playbackFrameRate: Double) -> Int {
        abs(playbackFrameRate - Double(fps)) < 0.0001 ? 1 : 1001
    }

    nonisolated private static func timingDenominator(fps: Int, playbackFrameRate: Double) -> Int {
        if abs(playbackFrameRate - Double(fps)) < 0.0001 {
            return fps
        }
        return fps * 1000
    }

    private struct FCPXMLTiming {
        let start: String
        let duration: String
        let frameDuration: String
        let tcFormat: String
    }

    enum ExportError: LocalizedError {
        case noMetadata
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noMetadata:
                "没有可导出的 Final Cut Pro XML 元数据字段"
            case .encodingFailed:
                "Final Cut Pro XML 文本编码失败"
            }
        }
    }
}

private enum XMLExportSupport {
    nonisolated static func commonRollName(rows: [FinalCutMetadataXMLRow]) -> String? {
        let rollNames = Set(rows.compactMap { trimmed($0.metadata.roll) })
        return rollNames.count == 1 ? rollNames.first : nil
    }

    nonisolated static func frameCount(duration: Double?, playbackFrameRate: Double) -> Int {
        guard let duration, duration.isFinite, playbackFrameRate > 0 else {
            return 1
        }

        return max(1, Int((duration * playbackFrameRate).rounded()))
    }

    nonisolated static func safeXMLID(stem: String, index: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let sanitized = stem.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        let base = sanitized.isEmpty ? "clip" : sanitized
        return "\(base)_\(index + 1)"
    }

    nonisolated static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        return value
    }

    nonisolated static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    nonisolated static func xmemlRateXML(for timecode: Timecode?) -> String {
        let fps = timecode?.fps ?? 25
        let playbackFrameRate = timecode?.playbackFrameRate ?? Double(fps)
        let isNTSC = abs(playbackFrameRate - Double(fps)) > 0.0001
        return """
        <rate>
          <ntsc>\(isNTSC ? "TRUE" : "FALSE")</ntsc>
          <timebase>\(fps)</timebase>
        </rate>
        """
    }
}

private extension String {
    nonisolated func indented(by spaces: Int) -> String {
        let prefix = String(repeating: " ", count: spaces)
        return split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
    }
}
