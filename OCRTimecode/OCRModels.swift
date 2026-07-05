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

    nonisolated var totalFrames: Int {
        (((hours * 60 + minutes) * 60 + seconds) * fps) + frames
    }

    nonisolated var description: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    nonisolated static func == (lhs: Timecode, rhs: Timecode) -> Bool {
        lhs.hours == rhs.hours
            && lhs.minutes == rhs.minutes
            && lhs.seconds == rhs.seconds
            && lhs.frames == rhs.frames
            && lhs.fps == rhs.fps
    }

    nonisolated static func < (lhs: Timecode, rhs: Timecode) -> Bool {
        lhs.totalFrames < rhs.totalFrames
    }

    nonisolated static func from(totalFrames rawFrames: Int, fps: Int) -> Timecode {
        let framesPerDay = fps * 60 * 60 * 24
        let totalFrames = ((rawFrames % framesPerDay) + framesPerDay) % framesPerDay
        let totalSeconds = totalFrames / fps
        let frames = totalFrames % fps
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = (totalSeconds / 3600) % 24
        return Timecode(hours: hours, minutes: minutes, seconds: seconds, frames: frames, fps: fps)
    }

    nonisolated static func parse(_ value: String, fps: Int) -> Timecode? {
        guard fps > 0 else {
            return nil
        }

        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ";", with: ":")
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

        return Timecode(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3], fps: fps)
    }
}

enum SourceTimecodeFrameRateSetting: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case automatic
    case fps24
    case fps25
    case fps30

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .automatic:
            "自动"
        case .fps24:
            "24"
        case .fps25:
            "25"
        case .fps30:
            "30"
        }
    }

    nonisolated var fps: Int? {
        switch self {
        case .automatic:
            nil
        case .fps24:
            24
        case .fps25:
            25
        case .fps30:
            30
        }
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
    var renamePrefix: String
    var renameSuffix: String

    nonisolated init(
        isTimecodeBurnEnabled: Bool = false,
        timecodeBurnOutputMode: TimecodeBurnOutputMode = .sourceFile,
        isFileRenameEnabled: Bool = false,
        exportsCompanionCSVForRenamedFiles: Bool = false,
        renamePrefix: String = "",
        renameSuffix: String = ""
    ) {
        self.isTimecodeBurnEnabled = isTimecodeBurnEnabled
        self.timecodeBurnOutputMode = timecodeBurnOutputMode
        self.isFileRenameEnabled = isFileRenameEnabled
        self.exportsCompanionCSVForRenamedFiles = exportsCompanionCSVForRenamedFiles
        self.renamePrefix = renamePrefix
        self.renameSuffix = renameSuffix
    }

    enum CodingKeys: String, CodingKey {
        case isTimecodeBurnEnabled
        case timecodeBurnOutputMode
        case isFileRenameEnabled
        case exportsCompanionCSVForRenamedFiles
        case renamePrefix
        case renameSuffix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isTimecodeBurnEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTimecodeBurnEnabled) ?? false
        timecodeBurnOutputMode = try container.decodeIfPresent(TimecodeBurnOutputMode.self, forKey: .timecodeBurnOutputMode) ?? .sourceFile
        isFileRenameEnabled = try container.decodeIfPresent(Bool.self, forKey: .isFileRenameEnabled) ?? false
        exportsCompanionCSVForRenamedFiles = try container.decodeIfPresent(Bool.self, forKey: .exportsCompanionCSVForRenamedFiles) ?? false
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
        return "\(sourceTimecodeFrameRate)"
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
                let frameCount = frameCount(duration: duration, fps: startTimecode.fps)
                let endFrame = max(frameCount - 1, 0)
                let endTimecode = Timecode.from(
                    totalFrames: startTimecode.totalFrames + endFrame,
                    fps: startTimecode.fps
                )

                fields.append(("Duration TC", Timecode.from(totalFrames: frameCount, fps: startTimecode.fps).description))
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

    nonisolated private static func frameCount(duration: Double, fps: Int) -> Int {
        guard duration.isFinite, fps > 0 else {
            return 1
        }

        return max(1, Int((duration * Double(fps)).rounded()))
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
                "没有可导出的达芬奇元数据字段"
            case .encodingFailed:
                "CSV 文本编码失败"
            }
        }
    }
}
