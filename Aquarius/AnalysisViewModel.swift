// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AVKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct TimecodeBurnJob: Sendable {
    let id: MediaQueueItem.ID
    let url: URL
    let timecode: Timecode

    nonisolated init(id: MediaQueueItem.ID, url: URL, timecode: Timecode) {
        self.id = id
        self.url = url
        self.timecode = timecode
    }
}

private struct FileOutputJob: Sendable {
    let id: MediaQueueItem.ID
    let sourceURL: URL
    let destinationURL: URL
    let timecode: Timecode?

    nonisolated init(
        id: MediaQueueItem.ID,
        sourceURL: URL,
        destinationURL: URL,
        timecode: Timecode? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.timecode = timecode
    }
}

private final class ModalButtonTarget: NSObject {
    let response: NSApplication.ModalResponse

    init(response: NSApplication.ModalResponse) {
        self.response = response
    }

    @objc func stopModal() {
        NSApp.stopModal(withCode: response)
    }
}

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published var mediaItems: [MediaQueueItem] = []
    @Published var selectedMediaItemID: MediaQueueItem.ID?
    @Published var player: AVPlayer?
    @Published var previewImage: NSImage?
    @Published var isPlaying = false
    @Published var currentPlaybackSeconds = 0.0
    @Published var playbackDuration = 0.0
    @Published var analyzingItemID: MediaQueueItem.ID?
    @Published var isBatchAnalyzing = false
    @Published var isBurningTimecode = false
    @Published var batchProgressMessage: String?
    @Published var statusMessage = "导入视频或文件夹后开始 OCR"
    @Published var errorMessage: String?
    @Published var previewDiagnosticMessage: String?
    @Published var regions = OCRRegion.qtakeLowerLeftPreset
    @Published var selectedRegionID = OCRRegion.qtakeLowerLeftPreset.first?.id ?? "clip-name"
    @Published var enabledFieldKinds = Set(OCRFieldKind.allCases)
    @Published var sourceTimecodeFrameRateSetting: SourceTimecodeFrameRateSetting = .automatic
    @Published var listRollOverrideDraft = ""
    @Published var listCameraIDOverrideDraft = ""
    @Published var roiPresets: [ROIPreset] = []
    @Published var selectedROIPresetID: ROIPreset.ID?
    @Published var isTimecodeBurnOptionEnabled = false {
        didSet { persistProjectOutputSettings() }
    }
    @Published var timecodeBurnOutputMode: TimecodeBurnOutputMode = .sourceFile {
        didSet { persistProjectOutputSettings() }
    }
    @Published var isFileRenameOptionEnabled = false {
        didSet {
            if isFileRenameOptionEnabled && !isLoadingProjectOutputSettings {
                exportsCompanionCSVForRenamedFiles = true
            }
            persistProjectOutputSettings()
        }
    }
    @Published var exportsCompanionCSVForRenamedFiles = false {
        didSet { persistProjectOutputSettings() }
    }
    @Published var showsTimecodeDiagnosticsDetails = false {
        didSet { persistProjectOutputSettings() }
    }
    @Published var renameOutputPrefix = "" {
        didSet { persistProjectOutputSettings() }
    }
    @Published var renameOutputSuffix = "" {
        didSet { persistProjectOutputSettings() }
    }

    private var securityScopedURL: URL?
    private var isUsingSecurityScopedAccess = false
    private var playerTimeObserver: Any?
    private var previewImageTask: Task<Void, Never>?
    private var playbackDurationTask: Task<Void, Never>?
    private var sourceMetadataTasks: [MediaQueueItem.ID: Task<Void, Never>] = [:]
    private var isLoadingProjectOutputSettings = false

    init() {
        migrateLegacyApplicationSupportIfNeeded()
        loadProjectOutputSettings()
        loadROIPresets()
    }

    deinit {
        previewImageTask?.cancel()
        playbackDurationTask?.cancel()
        sourceMetadataTasks.values.forEach { $0.cancel() }
        if isUsingSecurityScopedAccess {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
    }

    let sampleVideos: [SampleVideo] = [
        SampleVideo(
            fileName: "qtake_A001_bottom_left_24fps.mov",
            displayName: "A001 左下 24fps",
            regions: OCRRegion.qtakeLowerLeftPreset
        ),
        SampleVideo(
            fileName: "qtake_B014_upper_right_25fps.mov",
            displayName: "B014 右上 25fps",
            regions: [
                OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.540, y: 0.075, width: 0.430, height: 0.080)),
                OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.540, y: 0.145, width: 0.430, height: 0.065)),
                OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.540, y: 0.200, width: 0.430, height: 0.090))
            ]
        ),
        SampleVideo(
            fileName: "qtake_C003_bottom_right_30fps.mov",
            displayName: "C003 右下 30fps",
            regions: [
                OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.650, y: 0.705, width: 0.315, height: 0.090)),
                OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.660, y: 0.775, width: 0.305, height: 0.065)),
                OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.735, y: 0.835, width: 0.230, height: 0.090))
            ]
        ),
        SampleVideo(
            fileName: "qtake_D009_center_top_24fps.mov",
            displayName: "D009 顶部 24fps",
            regions: [
                OCRRegion(id: "clip-name", label: "文件名", kind: .clipName, normalizedRect: CGRect(x: 0.270, y: 0.075, width: 0.460, height: 0.080)),
                OCRRegion(id: "roll", label: "卷号", kind: .roll, normalizedRect: CGRect(x: 0.270, y: 0.145, width: 0.460, height: 0.065)),
                OCRRegion(id: "timecode", label: "时间码", kind: .timecode, normalizedRect: CGRect(x: 0.270, y: 0.200, width: 0.460, height: 0.090))
            ]
        )
    ]

    var sampleURL: URL? {
        sampleVideos.first.flatMap(sampleURL(for:))
    }

    var selectedMediaItem: MediaQueueItem? {
        guard let selectedMediaItemID else {
            return nil
        }
        return mediaItems.first { $0.id == selectedMediaItemID }
    }

    var selectedVideoURL: URL? {
        selectedMediaItem?.url
    }

    var result: ClipOCRResult? {
        selectedMediaItem?.result
    }

    var sourceMetadataFields: [MetadataField] {
        selectedMediaItem?.sourceMetadataFields ?? []
    }

    var sourceMetadataStatus: String {
        selectedMediaItem?.sourceMetadataStatus ?? "未选择素材"
    }

    var isLoadingSourceMetadata: Bool {
        selectedMediaItem?.isLoadingSourceMetadata ?? false
    }

    var selectedTimecodeMetadata: QuickTimeTimecodeMetadata? {
        selectedMediaItem?.sourceTimecodeMetadata
    }

    var selectedResultIsStale: Bool {
        selectedMediaItem.map(isAnalysisStale) ?? false
    }

    var isAnalyzing: Bool {
        analyzingItemID != nil || isBatchAnalyzing || isBurningTimecode
    }

    var hasEnabledFields: Bool {
        !enabledFieldKinds.isEmpty
    }

    var enabledRegions: [OCRRegion] {
        regions.filter { enabledFieldKinds.contains($0.kind) }
    }

    var playbackPositionText: String {
        "\(formatClock(currentPlaybackSeconds)) / \(formatClock(playbackDuration))"
    }

    var currentFrameText: String {
        "\(currentFrameOffset)"
    }

    var currentSourceTimecodeText: String {
        guard let item = selectedMediaItem,
              let startTimecode = exportMetadata(for: item).startTimecode else {
            return "--:--:--:--"
        }

        return Timecode.from(
            totalFrames: startTimecode.totalFrames + currentFrameOffset,
            fps: startTimecode.fps
        ).description
    }

    var exportableItemCount: Int {
        exportableRows.count
    }

    var skippedExportItemCount: Int {
        max(0, mediaItems.count - exportableItemCount)
    }

    var hasAnalysisRecords: Bool {
        mediaItems.contains { item in
            item.result != nil || item.errorMessage != nil || item.analysisStatus != .pending
        }
    }

    var canExportDaVinciMetadata: Bool {
        exportableItemCount > 0
    }

    var shouldShowTimecodeBurnButton: Bool {
        isTimecodeBurnOptionEnabled
    }

    var shouldShowFileRenameButton: Bool {
        isFileRenameOptionEnabled
    }

    var shouldShowBurnAndRenameButton: Bool {
        isTimecodeBurnOptionEnabled && isFileRenameOptionEnabled
    }

    var canBurnTimecodeIntoTMCD: Bool {
        !mediaItems.isEmpty
            && !isAnalyzing
            && timecodeBurnJobs.count == mediaItems.count
    }

    var canCopyFilesWithMetadataNames: Bool {
        !mediaItems.isEmpty
            && !isAnalyzing
            && mediaItems.allSatisfy { exportMetadata(for: $0).clipName != nil }
    }

    var canBurnAndRenameFiles: Bool {
        canBurnTimecodeIntoTMCD && canCopyFilesWithMetadataNames
    }

    var timecodeBurnButtonHelp: String {
        switch timecodeBurnOutputMode {
        case .sourceFile:
            "将有效起始时间码写入源文件已有 TMCD 轨道"
        case .copyToFolder:
            "复制到新文件夹后写入 TMCD；源文件不变"
        }
    }

    var updatedMetadataFields: [MetadataField] {
        guard let item = selectedMediaItem else {
            return []
        }

        let metadata = exportMetadata(for: item)
        guard DaVinciMetadataCSVExporter.hasExportableMetadata(metadata) else {
            return []
        }

        return DaVinciMetadataCSVExporter
            .exportFields(videoURL: item.url, metadata: metadata)
            .map { MetadataField(label: Self.localizedMetadataLabel(for: $0.header), value: $0.value) }
    }

    var selectedManualClipName: String {
        selectedMediaItem?.manualMetadata.clipName ?? ""
    }

    var selectedManualStartTimecode: String {
        selectedMediaItem?.manualMetadata.startTimecode ?? ""
    }

    var selectedHasManualMetadataOverrides: Bool {
        selectedMediaItem?.manualMetadata.hasAnyOverride ?? false
    }

    var selectedManualTimecodeFrameRate: Int {
        guard let item = selectedMediaItem else {
            return sourceTimecodeFrameRateSetting.fps ?? 24
        }
        return timecodeFrameRateForManualEntry(item)
    }

    var selectedManualStartTimecodeError: String? {
        guard let item = selectedMediaItem,
              let value = item.manualMetadata.trimmedStartTimecode else {
            return nil
        }

        let fps = timecodeFrameRateForManualEntry(item)
        guard Timecode.parse(value, fps: fps) != nil else {
            return "起始时间码需为 HH:MM:SS:FF，且帧号小于 \(fps)"
        }
        return nil
    }

    var selectedEffectiveClipName: String? {
        selectedMediaItem.map { exportMetadata(for: $0).clipName } ?? nil
    }

    var selectedEffectiveRoll: String? {
        selectedMediaItem.map { exportMetadata(for: $0).roll } ?? nil
    }

    var selectedEffectiveCameraID: String? {
        selectedMediaItem.map { exportMetadata(for: $0).cameraID } ?? nil
    }

    var selectedEffectiveStartTimecode: Timecode? {
        selectedMediaItem.map { exportMetadata(for: $0).startTimecode } ?? nil
    }

    func loadSample() {
        guard let sample = sampleVideos.first else {
            errorMessage = "没有配置样片"
            return
        }
        loadSample(sample)
    }

    func loadSample(_ sample: SampleVideo) {
        guard let url = sampleURL(for: sample) else {
            errorMessage = "没有在 App bundle 中找到样片资源"
            return
        }
        applySampleRegions(sample.regions)
        setVideo(url, shouldApplyKnownSamplePreset: false)
    }

    func setVideo(_ url: URL, shouldApplyKnownSamplePreset: Bool = true) {
        let appliedPresetName = shouldApplyKnownSamplePreset ? applyKnownSamplePreset(for: url) : nil
        let addedCount = addMediaFiles([url], selectFirstNew: true)

        if let itemID = itemID(for: url) {
            selectMediaItem(itemID)
        }

        let suffix = appliedPresetName.map { "，已套用 \($0) ROI" } ?? ""
        if addedCount == 0 {
            statusMessage = "已选择 \(url.lastPathComponent)\(suffix)"
        } else {
            statusMessage = "已加入并选择 \(url.lastPathComponent)\(suffix)"
        }
    }

    @discardableResult
    func addMediaFiles(_ urls: [URL], selectFirstNew: Bool = true) -> Int {
        guard !isBatchAnalyzing else {
            errorMessage = "批量提取时暂不能导入素材"
            return 0
        }

        let videoURLs = urls
            .map { $0.standardizedFileURL }
            .filter(Self.isSupportedVideoURL)

        guard !videoURLs.isEmpty else {
            errorMessage = "没有找到可导入的视频文件"
            return 0
        }

        let existingPaths = Set(mediaItems.map { normalizedPath($0.url) })
        var addedItems: [MediaQueueItem] = []
        var knownPaths = existingPaths

        for url in videoURLs.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let path = normalizedPath(url)
            guard !knownPaths.contains(path) else {
                continue
            }
            knownPaths.insert(path)
            addedItems.append(MediaQueueItem(url: url))
        }

        guard !addedItems.isEmpty else {
            statusMessage = "素材已在列表中"
            return 0
        }

        mediaItems.append(contentsOf: addedItems)
        if selectFirstNew, let firstID = addedItems.first?.id {
            selectMediaItem(firstID)
        } else if selectedMediaItemID == nil, let firstID = mediaItems.first?.id {
            selectMediaItem(firstID)
        }

        errorMessage = nil
        statusMessage = "已加入 \(addedItems.count) 个视频"
        return addedItems.count
    }

    @discardableResult
    func addMediaFolder(_ folderURL: URL) -> Int {
        guard !isBatchAnalyzing else {
            errorMessage = "批量提取时暂不能导入素材"
            return 0
        }

        let scopedAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let urls = videoURLs(in: folderURL)
        let addedCount = addMediaFiles(urls, selectFirstNew: selectedMediaItemID == nil)
        if addedCount > 0 {
            statusMessage = "已从文件夹导入 \(addedCount) 个视频"
        } else if errorMessage == nil {
            statusMessage = "文件夹中没有新的可导入视频"
        }
        return addedCount
    }

    func promptImportMediaFiles() {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再导入素材"
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "选择视频文件"
        openPanel.prompt = "加入"
        openPanel.allowedContentTypes = Self.supportedVideoContentTypes
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false

        guard openPanel.runModal() == .OK else {
            return
        }

        addMediaFiles(openPanel.urls)
    }

    func promptImportMediaFolder() {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再导入素材"
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.title = "选择 Qtake 视频文件夹"
        openPanel.prompt = "导入"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = false

        guard openPanel.runModal() == .OK, let folderURL = openPanel.url else {
            return
        }

        addMediaFolder(folderURL)
    }

    func addDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        guard !isBatchAnalyzing else {
            errorMessage = "批量提取时暂不能导入素材"
            return
        }

        var fileURLs: [URL] = []
        var addedCount = 0

        for url in urls {
            if isDirectoryURL(url) {
                addedCount += addMediaFolder(url)
            } else {
                fileURLs.append(url)
            }
        }

        if !fileURLs.isEmpty {
            addedCount += addMediaFiles(fileURLs, selectFirstNew: selectedMediaItemID == nil)
        }

        if addedCount > 0 {
            statusMessage = "已拖入添加 \(addedCount) 个视频"
        } else if errorMessage == nil {
            statusMessage = "拖入内容中没有新的可导入视频"
        }
    }

    func selectMediaItem(_ id: MediaQueueItem.ID) {
        guard mediaItems.contains(where: { $0.id == id }) else {
            return
        }

        selectedMediaItemID = id
        loadSelectedMediaForPreview()
    }

    func selectPreviousMediaItem() {
        selectAdjacentMediaItem(offset: -1)
    }

    func selectNextMediaItem() {
        selectAdjacentMediaItem(offset: 1)
    }

    func removeMediaItem(_ id: MediaQueueItem.ID) {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再删除素材"
            return
        }
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        sourceMetadataTasks[id]?.cancel()
        sourceMetadataTasks[id] = nil
        let removedWasSelected = selectedMediaItemID == id
        mediaItems.remove(at: index)

        if removedWasSelected {
            if mediaItems.indices.contains(index) {
                selectMediaItem(mediaItems[index].id)
            } else if let lastID = mediaItems.last?.id {
                selectMediaItem(lastID)
            } else {
                selectedMediaItemID = nil
                unloadCurrentVideo()
                statusMessage = "列表已清空"
            }
        }
    }

    func clearMediaList() {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再清空列表"
            return
        }

        sourceMetadataTasks.values.forEach { $0.cancel() }
        sourceMetadataTasks.removeAll()
        mediaItems.removeAll()
        selectedMediaItemID = nil
        unloadCurrentVideo()
        errorMessage = nil
        statusMessage = "已清空媒体列表"
    }

    func clearAnalysisResult(id: MediaQueueItem.ID) {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再清除提取结果"
            return
        }
        guard let item = mediaItems.first(where: { $0.id == id }) else {
            return
        }

        updateMediaItem(id) { item in
            item.analysisStatus = .pending
            item.result = nil
            item.errorMessage = nil
        }
        statusMessage = "已清除提取结果：\(item.displayName)"
    }

    func clearAllAnalysisResults() {
        guard !isAnalyzing else {
            errorMessage = "识别进行中，请完成后再清除提取结果"
            return
        }

        var clearedCount = 0
        for id in mediaItems.map(\.id) {
            guard let item = mediaItems.first(where: { $0.id == id }),
                  item.result != nil || item.errorMessage != nil || item.analysisStatus != .pending else {
                continue
            }

            updateMediaItem(id) { item in
                item.analysisStatus = .pending
                item.result = nil
                item.errorMessage = nil
            }
            clearedCount += 1
        }

        statusMessage = clearedCount > 0 ? "已清除 \(clearedCount) 个提取结果" : "没有可清除的提取结果"
    }

    func setSelectedManualClipName(_ value: String) {
        guard let selectedMediaItemID else {
            return
        }

        updateMediaItem(selectedMediaItemID) { item in
            item.manualMetadata.clipName = value
        }
    }

    func setSelectedManualStartTimecode(_ value: String) {
        guard let selectedMediaItemID else {
            return
        }

        updateMediaItem(selectedMediaItemID) { item in
            item.manualMetadata.startTimecode = value
        }
    }

    func clearSelectedManualMetadata() {
        guard let selectedMediaItemID,
              let item = selectedMediaItem else {
            errorMessage = "请先选择一个素材"
            return
        }

        updateMediaItem(selectedMediaItemID) { item in
            item.manualMetadata = ManualMetadataOverrides()
        }
        statusMessage = "已清除当前片段手动元数据：\(item.displayName)"
    }

    func applyListRollOverride() {
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入素材"
            return
        }

        let value = listRollOverrideDraft
        for id in mediaItems.map(\.id) {
            updateMediaItem(id) { item in
                item.manualMetadata.roll = value
                if let cameraID = ManualMetadataOverrides.cameraID(from: value) {
                    item.manualMetadata.cameraID = cameraID
                }
            }
        }

        let action = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "清除" : "应用"
        statusMessage = "已\(action)当前列表 \(mediaItems.count) 个素材的手动卷号"
    }

    func applyListCameraIDOverride() {
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入素材"
            return
        }

        let value = listCameraIDOverrideDraft
        for id in mediaItems.map(\.id) {
            updateMediaItem(id) { item in
                item.manualMetadata.cameraID = value
            }
        }

        let action = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "清除" : "应用"
        statusMessage = "已\(action)当前列表 \(mediaItems.count) 个素材的手动机位号"
    }

    func playOrPause() {
        guard let player else {
            return
        }

        if player.rate != 0 {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
    }

    func shuttleBackward() {
        guard let player else {
            return
        }

        if player.currentItem?.canPlayReverse == true {
            player.rate = -1
            isPlaying = true
        } else {
            seek(by: -1)
        }
    }

    func shuttleForward() {
        guard let player else {
            return
        }

        player.rate = 1
        isPlaying = true
    }

    func seekToStart() {
        pausePlayback()
        seek(to: 0)
    }

    func seekToEnd() {
        pausePlayback()
        seek(to: playbackDuration)
    }

    func seek(by deltaSeconds: Double) {
        seek(to: currentPlaybackSeconds + deltaSeconds)
    }

    func seek(to seconds: Double) {
        let upperBound = playbackDuration > 0 ? playbackDuration : max(currentPlaybackSeconds, 0)
        let clampedSeconds = min(max(seconds, 0), upperBound)
        currentPlaybackSeconds = clampedSeconds
        player?.seek(
            to: CMTime(seconds: clampedSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func resetRegionsToPreset() {
        regions = OCRRegion.qtakeLowerLeftPreset
        selectedROIPresetID = roiPresets.first(where: { $0.name == Self.defaultROIPreset.name })?.id
        selectFirstEnabledRegionIfNeeded()
        statusMessage = "已重置为左下角 Qtake 预设 ROI"
    }

    func updateSelectedRegion(to normalizedRect: CGRect) {
        guard let index = regions.firstIndex(where: { $0.id == selectedRegionID }),
              enabledFieldKinds.contains(regions[index].kind) else {
            return
        }

        regions[index].normalizedRect = normalizedRect
        selectedROIPresetID = nil
        statusMessage = "已更新 \(regions[index].kind.title) 检测区域"
    }

    func isFieldEnabled(_ kind: OCRFieldKind) -> Bool {
        enabledFieldKinds.contains(kind)
    }

    func setField(_ kind: OCRFieldKind, isEnabled: Bool) {
        if isEnabled {
            enabledFieldKinds.insert(kind)
        } else {
            enabledFieldKinds.remove(kind)
        }

        selectFirstEnabledRegionIfNeeded()
        statusMessage = hasEnabledFields ? "已更新识别字段开关" : "请至少开启一个识别字段"
    }

    func setSourceTimecodeFrameRateSetting(_ setting: SourceTimecodeFrameRateSetting) {
        guard sourceTimecodeFrameRateSetting != setting else {
            return
        }

        sourceTimecodeFrameRateSetting = setting
        let affectedCount = mediaItems.filter { isAnalysisStale($0) }.count
        let suffix = affectedCount > 0 ? "，\(affectedCount) 个已有结果需重新提取" : ""
        statusMessage = "已更新源时间码帧率：\(setting.title)\(suffix)"
    }

    func analyzeSelectedVideo() async {
        guard let selectedMediaItemID else {
            errorMessage = "请先选择一个视频"
            return
        }
        await analyzeMediaItem(id: selectedMediaItemID)
    }

    func analyzeMediaItem(id: MediaQueueItem.ID) async {
        guard !isAnalyzing else {
            errorMessage = "已有识别任务正在进行"
            return
        }
        guard hasEnabledFields else {
            errorMessage = "请至少开启一个识别字段"
            statusMessage = "无法开始：未开启识别字段"
            return
        }

        await runAnalysis(for: id, regions: enabledRegions, progressPrefix: nil)
    }

    func analyzeAllMediaItems() async {
        guard !isAnalyzing else {
            errorMessage = "已有识别任务正在进行"
            return
        }
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入视频"
            return
        }
        guard hasEnabledFields else {
            errorMessage = "请至少开启一个识别字段"
            statusMessage = "无法开始：未开启识别字段"
            return
        }

        let ids = mediaItems
            .filter { $0.result == nil || isAnalysisStale($0) }
            .map(\.id)
        let skippedExistingCount = mediaItems.count - ids.count
        guard !ids.isEmpty else {
            errorMessage = nil
            batchProgressMessage = nil
            statusMessage = "当前列表都已提取且设置未变化，未重复提取"
            return
        }

        let regionsSnapshot = enabledRegions
        isBatchAnalyzing = true
        errorMessage = nil
        batchProgressMessage = "准备批量提取..."

        for (offset, id) in ids.enumerated() {
            guard mediaItems.contains(where: { $0.id == id }) else {
                continue
            }
            batchProgressMessage = "正在提取 \(offset + 1) / \(ids.count)"
            await runAnalysis(
                for: id,
                regions: regionsSnapshot,
                progressPrefix: "[\(offset + 1)/\(ids.count)] "
            )
        }

        isBatchAnalyzing = false
        analyzingItemID = nil
        let completedThisRun = ids.filter { id in
            mediaItems.first(where: { $0.id == id })?.result != nil
        }.count
        let failedThisRun = ids.filter { id in
            mediaItems.first(where: { $0.id == id })?.analysisStatus == .failed
        }.count
        let skippedText = skippedExistingCount > 0 ? "，跳过 \(skippedExistingCount) 个已提取" : ""
        batchProgressMessage = "本次完成 \(completedThisRun) 个，失败 \(failedThisRun) 个\(skippedText)"
        statusMessage = "批量提取完成：本次 \(completedThisRun) 个完成，\(failedThisRun) 个失败\(skippedText)"
    }

    func exportDaVinciMetadataCSV() {
        let rows = exportableRows
        guard !rows.isEmpty else {
            errorMessage = "当前列表没有可导出的达芬奇元数据"
            statusMessage = "导出失败：没有可导出条目"
            return
        }

        let csvData: Data
        do {
            csvData = try DaVinciMetadataCSVExporter.makeData(rows: rows)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "导出达芬奇 CSV 失败"
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = "Aquarius_DaVinci_Metadata.csv"

        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            return
        }

        do {
            try csvData.write(to: destination, options: .atomic)
            errorMessage = nil
            let skippedText = skippedExportItemCount > 0 ? "，跳过 \(skippedExportItemCount) 个" : ""
            statusMessage = "已导出 \(rows.count) 条达芬奇 CSV\(skippedText)：\(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "导出达芬奇 CSV 失败"
        }
    }

    func runTimecodeBurnAction() {
        switch timecodeBurnOutputMode {
        case .sourceFile:
            confirmAndBurnTimecodeIntoTMCD()
        case .copyToFolder:
            copyAndBurnTimecodeIntoNewFolder()
        }
    }

    func copyFilesWithMetadataNames() {
        guard !isAnalyzing else {
            errorMessage = "当前有任务正在进行，请完成后再复制改名"
            return
        }
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入视频"
            return
        }
        guard canCopyFilesWithMetadataNames else {
            let missingCount = mediaItems.filter { exportMetadata(for: $0).clipName == nil }.count
            errorMessage = "还有 \(missingCount) 个素材没有有效文件名，请先提取或手动输入"
            statusMessage = "无法改名：列表文件名不完整"
            return
        }
        guard let folderURL = promptForOutputFolder(title: "选择改名输出文件夹", prompt: "复制并改名") else {
            return
        }

        let jobs = makeFileOutputJobs(destinationFolder: folderURL, requiresClipName: true, requiresTimecode: false, forceMOVExtension: false)
        Task {
            await copyFiles(jobs: jobs, destinationFolder: folderURL, operationTitle: "复制改名")
        }
    }

    func burnTimecodeAndRenameIntoNewFolder() {
        guard !isAnalyzing else {
            errorMessage = "当前有任务正在进行，请完成后再烧录并改名"
            return
        }
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入视频"
            return
        }
        guard canBurnAndRenameFiles else {
            let missingTimecodeCount = mediaItems.filter { exportMetadata(for: $0).startTimecode == nil }.count
            let missingNameCount = mediaItems.filter { exportMetadata(for: $0).clipName == nil }.count
            errorMessage = "列表元数据不完整：\(missingTimecodeCount) 个缺少时间码，\(missingNameCount) 个缺少文件名"
            statusMessage = "无法烧录并改名：列表元数据不完整"
            return
        }
        guard let folderURL = promptForOutputFolder(title: "选择烧录并改名输出文件夹", prompt: "烧录并改名") else {
            return
        }

        let jobs = makeFileOutputJobs(destinationFolder: folderURL, requiresClipName: true, requiresTimecode: true, forceMOVExtension: true)
        Task {
            await copyAndBurnTimecode(jobs: jobs, destinationFolder: folderURL, renameOutputs: true)
        }
    }

    func confirmAndBurnTimecodeIntoTMCD() {
        guard !isAnalyzing else {
            errorMessage = "当前有任务正在进行，请完成后再烧录时间码"
            return
        }
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入视频"
            return
        }

        let jobs = timecodeBurnJobs
        guard jobs.count == mediaItems.count else {
            let missingCount = max(0, mediaItems.count - jobs.count)
            errorMessage = "还有 \(missingCount) 个素材没有有效起始时间码，请先提取或手动输入"
            statusMessage = "无法烧录：列表时间码不完整"
            return
        }

        let missingTMCD = jobs.filter { !QuickTimeTMCDWriter.hasWritableTMCDTrack(in: $0.url) }
        guard missingTMCD.isEmpty else {
            let sampleText = missingTMCD
                .prefix(4)
                .map { $0.url.lastPathComponent }
                .joined(separator: "\n")
            errorMessage = "有 \(missingTMCD.count) 个素材没有可写入的 QuickTime TMCD 轨道，不能直接烧录源文件。\n\(sampleText)\n可在项目设置里改为“复制到新文件夹并烧录”。"
            statusMessage = "无法烧录源文件：缺少 TMCD 轨道"
            return
        }

        guard runBurnTimecodeConfirmationPanel(fileCount: jobs.count) else {
            return
        }

        Task {
            await burnTimecodeIntoTMCD(jobs: jobs)
        }
    }

    private func copyAndBurnTimecodeIntoNewFolder() {
        guard !isAnalyzing else {
            errorMessage = "当前有任务正在进行，请完成后再烧录时间码"
            return
        }
        guard !mediaItems.isEmpty else {
            errorMessage = "请先导入视频"
            return
        }

        let jobs = timecodeBurnJobs
        guard jobs.count == mediaItems.count else {
            let missingCount = max(0, mediaItems.count - jobs.count)
            errorMessage = "还有 \(missingCount) 个素材没有有效起始时间码，请先提取或手动输入"
            statusMessage = "无法烧录：列表时间码不完整"
            return
        }
        guard let folderURL = promptForOutputFolder(title: "选择时间码烧录输出文件夹", prompt: "复制并烧录") else {
            return
        }

        let outputJobs = makeFileOutputJobs(destinationFolder: folderURL, requiresClipName: false, requiresTimecode: true, forceMOVExtension: true)
        Task {
            await copyAndBurnTimecode(jobs: outputJobs, destinationFolder: folderURL, renameOutputs: false)
        }
    }

    private func runBurnTimecodeConfirmationPanel(fileCount: Int) -> Bool {
        let panelSize = NSSize(width: 280, height: 280)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "烧录时间码"
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.contentMinSize = panelSize
        panel.contentMaxSize = panelSize

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        panel.contentView = contentView
        panel.setContentSize(panelSize)

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "确认烧录时间码？")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: """
        会修改当前列表 \(fileCount) 个源文件的 QuickTime TMCD 轨道，Resolve 等软件读取到的源时间码会改变。

        建议先备份原始文件。不会重编码画面；仅支持已有 TMCD 轨道的 MOV/QuickTime 文件，帧率不一致时请复核。
        """)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.alignment = .left
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = panelSize.width - 28
        messageLabel.textColor = .labelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let confirmButton = NSButton(title: "确认烧录", target: nil, action: nil)
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"
        confirmButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        contentView.addSubview(cancelButton)
        contentView.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            iconView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 52),
            iconView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: cancelButton.topAnchor, constant: -9),

            confirmButton.leadingAnchor.constraint(equalTo: contentView.centerXAnchor, constant: 6),
            confirmButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            confirmButton.widthAnchor.constraint(equalToConstant: 96),
            confirmButton.heightAnchor.constraint(equalToConstant: 32),

            cancelButton.trailingAnchor.constraint(equalTo: contentView.centerXAnchor, constant: -6),
            cancelButton.bottomAnchor.constraint(equalTo: confirmButton.bottomAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 96),
            cancelButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        let cancelTarget = ModalButtonTarget(response: .cancel)
        let confirmTarget = ModalButtonTarget(response: .OK)
        cancelButton.action = #selector(ModalButtonTarget.stopModal)
        cancelButton.target = cancelTarget
        confirmButton.action = #selector(ModalButtonTarget.stopModal)
        confirmButton.target = confirmTarget

        panel.defaultButtonCell = confirmButton.cell as? NSButtonCell
        panel.center()

        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        _ = cancelTarget
        _ = confirmTarget
        return response == .OK
    }

    func applyROIPreset(_ id: ROIPreset.ID) {
        guard let preset = roiPresets.first(where: { $0.id == id }) else {
            return
        }

        regions = preset.ocrRegions
        selectedROIPresetID = preset.id
        selectFirstEnabledRegionIfNeeded()
        statusMessage = "已套用 ROI 预设：\(preset.name)"
    }

    func promptSaveCurrentROIPreset() {
        let defaultName = "ROI \(DateFormatter.roiPresetName.string(from: Date()))"
        guard let name = promptForText(
            title: "保存 ROI 预设",
            message: "为当前检测区域配置命名。",
            defaultValue: defaultName,
            confirmTitle: "保存"
        ) else {
            return
        }
        saveCurrentROIPreset(named: name)
    }

    func saveCurrentROIPreset(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "ROI 预设名称不能为空"
            return
        }

        let preset = ROIPreset(name: uniquePresetName(trimmedName), regions: regions)
        roiPresets.append(preset)
        selectedROIPresetID = preset.id
        persistROIPresets()
        statusMessage = "已保存 ROI 预设：\(preset.name)"
    }

    func promptRenameSelectedROIPreset() {
        guard let selectedROIPresetID,
              let preset = roiPresets.first(where: { $0.id == selectedROIPresetID }) else {
            errorMessage = "请先选择一个 ROI 预设"
            return
        }

        guard let name = promptForText(
            title: "重命名 ROI 预设",
            message: "输入新的预设名称。",
            defaultValue: preset.name,
            confirmTitle: "重命名"
        ) else {
            return
        }

        renameROIPreset(id: selectedROIPresetID, to: name)
    }

    func renameROIPreset(id: ROIPreset.ID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "ROI 预设名称不能为空"
            return
        }
        guard let index = roiPresets.firstIndex(where: { $0.id == id }) else {
            return
        }

        roiPresets[index].name = uniquePresetName(trimmedName, excluding: id)
        roiPresets[index].updatedAt = Date()
        persistROIPresets()
        statusMessage = "已重命名 ROI 预设"
    }

    func deleteSelectedROIPreset() {
        guard let selectedROIPresetID,
              let index = roiPresets.firstIndex(where: { $0.id == selectedROIPresetID }) else {
            errorMessage = "请先选择一个 ROI 预设"
            return
        }

        let deletedName = roiPresets[index].name
        roiPresets.remove(at: index)
        self.selectedROIPresetID = roiPresets.first?.id
        if let nextID = self.selectedROIPresetID {
            applyROIPreset(nextID)
        }
        persistROIPresets()
        statusMessage = "已删除 ROI 预设：\(deletedName)"
    }

    func importROIPresets() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false

        guard openPanel.runModal() == .OK else {
            return
        }

        var importedCount = 0
        for url in openPanel.urls {
            do {
                let data = try Data(contentsOf: url)
                let presets = try decodeROIPresets(from: data)
                for preset in presets {
                    roiPresets.append(importedPreset(from: preset))
                    importedCount += 1
                }
            } catch {
                errorMessage = "导入 ROI 预设失败：\(error.localizedDescription)"
            }
        }

        if importedCount > 0 {
            if let lastPreset = roiPresets.last {
                regions = lastPreset.ocrRegions
                selectedROIPresetID = lastPreset.id
                selectFirstEnabledRegionIfNeeded()
            }
            persistROIPresets()
            statusMessage = "已导入 \(importedCount) 个 ROI 预设"
        }
    }

    func exportSelectedROIPreset() {
        guard let selectedROIPresetID,
              let preset = roiPresets.first(where: { $0.id == selectedROIPresetID }) else {
            errorMessage = "请先选择一个 ROI 预设"
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = "\(preset.name)_ROI.json"

        guard savePanel.runModal() == .OK, let destination = savePanel.url else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(preset)
            try data.write(to: destination, options: .atomic)
            errorMessage = nil
            statusMessage = "已导出 ROI 预设：\(destination.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "导出 ROI 预设失败"
        }
    }

    private var exportableRows: [DaVinciMetadataCSVRow] {
        mediaItems.compactMap { item in
            let metadata = exportMetadata(for: item)
            guard DaVinciMetadataCSVExporter.hasExportableMetadata(metadata) else {
                return nil
            }
            return DaVinciMetadataCSVRow(videoURL: item.url, metadata: metadata)
        }
    }

    private var timecodeBurnJobs: [TimecodeBurnJob] {
        mediaItems.compactMap { item in
            guard let startTimecode = exportMetadata(for: item).startTimecode else {
                return nil
            }
            return TimecodeBurnJob(id: item.id, url: item.url, timecode: startTimecode)
        }
    }

    private func promptForOutputFolder(title: String, prompt: String) -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = title
        openPanel.prompt = prompt
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true

        guard openPanel.runModal() == .OK, let folderURL = openPanel.url else {
            return nil
        }
        return folderURL
    }

    private func makeFileOutputJobs(
        destinationFolder: URL,
        requiresClipName: Bool,
        requiresTimecode: Bool,
        forceMOVExtension: Bool
    ) -> [FileOutputJob] {
        var usedFileNames = Set<String>()
        return mediaItems.compactMap { item in
            let metadata = exportMetadata(for: item)
            let outputStem: String
            if requiresClipName {
                guard let clipName = metadata.clipName else {
                    return nil
                }
                outputStem = outputFileStem(for: clipName)
            } else {
                outputStem = item.url.deletingPathExtension().lastPathComponent
            }

            let timecode: Timecode?
            if requiresTimecode {
                guard let startTimecode = metadata.startTimecode else {
                    return nil
                }
                timecode = startTimecode
            } else {
                timecode = nil
            }

            let fileExtension = forceMOVExtension ? "mov" : normalizedFileExtension(for: item.url)
            let destinationURL = uniqueDestinationURL(
                in: destinationFolder,
                stem: outputStem,
                fileExtension: fileExtension,
                usedFileNames: &usedFileNames
            )
            return FileOutputJob(id: item.id, sourceURL: item.url, destinationURL: destinationURL, timecode: timecode)
        }
    }

    private func outputFileStem(for clipName: String) -> String {
        let rawName = "\(renameOutputPrefix)\(clipName)\(renameOutputSuffix)"
        let invalidCharacters = CharacterSet(charactersIn: "/:\0")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = rawName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private func normalizedFileExtension(for url: URL) -> String {
        let pathExtension = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return pathExtension.isEmpty ? "mov" : pathExtension
    }

    private func uniqueDestinationURL(
        in folderURL: URL,
        stem: String,
        fileExtension: String,
        usedFileNames: inout Set<String>
    ) -> URL {
        let sanitizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var suffixIndex = 0

        while true {
            let candidateStem = suffixIndex == 0 ? stem : "\(stem)-\(suffixIndex)"
            let fileName = sanitizedExtension.isEmpty ? candidateStem : "\(candidateStem).\(sanitizedExtension)"
            let normalizedName = fileName.lowercased()
            let candidateURL = folderURL.appendingPathComponent(fileName, isDirectory: false)
            if !usedFileNames.contains(normalizedName),
               !FileManager.default.fileExists(atPath: candidateURL.path) {
                usedFileNames.insert(normalizedName)
                return candidateURL
            }
            suffixIndex += 1
        }
    }

    private var currentFrameOffset: Int {
        let fps = selectedMediaItem.map(timecodeFrameRateForManualEntry) ?? 24
        return max(0, Int(floor(currentPlaybackSeconds * Double(fps))))
    }

    private func copyFiles(jobs: [FileOutputJob], destinationFolder: URL, operationTitle: String) async {
        guard !jobs.isEmpty else {
            return
        }

        pausePlayback()
        isBurningTimecode = true
        errorMessage = nil
        batchProgressMessage = "准备\(operationTitle)..."
        defer {
            isBurningTimecode = false
            analyzingItemID = nil
        }

        let scopedFolderAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if scopedFolderAccess {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
        }

        var successCount = 0
        var failures: [(fileName: String, message: String)] = []
        var successfulJobs: [FileOutputJob] = []

        for (offset, job) in jobs.enumerated() {
            guard mediaItems.contains(where: { $0.id == job.id }) else {
                continue
            }

            analyzingItemID = job.id
            batchProgressMessage = "正在\(operationTitle) \(offset + 1) / \(jobs.count)"
            statusMessage = "正在\(operationTitle) \(job.sourceURL.lastPathComponent) -> \(job.destinationURL.lastPathComponent)"

            let scopedSourceAccess = job.sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scopedSourceAccess {
                    job.sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: job.sourceURL, to: job.destinationURL)
                }.value
                successCount += 1
                successfulJobs.append(job)
            } catch {
                failures.append((job.sourceURL.lastPathComponent, error.localizedDescription))
            }
        }

        let companionCSVFileName = writeRenamedCompanionCSVIfNeeded(
            successfulJobs: successfulJobs,
            destinationFolder: destinationFolder,
            failures: &failures
        )

        finishFileOutput(
            operationTitle: operationTitle,
            successCount: successCount,
            failures: failures,
            companionCSVFileName: companionCSVFileName,
            successMessage: "已\(operationTitle) \(successCount) 个文件到 \(destinationFolder.lastPathComponent)"
        )
    }

    private func copyAndBurnTimecode(jobs: [FileOutputJob], destinationFolder: URL, renameOutputs: Bool) async {
        guard !jobs.isEmpty else {
            return
        }

        pausePlayback()
        isBurningTimecode = true
        errorMessage = nil
        batchProgressMessage = "准备复制烧录..."
        defer {
            isBurningTimecode = false
            analyzingItemID = nil
        }

        let scopedFolderAccess = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if scopedFolderAccess {
                destinationFolder.stopAccessingSecurityScopedResource()
            }
        }

        let operationTitle = renameOutputs ? "烧录并改名" : "复制烧录"
        var successCount = 0
        var failures: [(fileName: String, message: String)] = []
        var successfulJobs: [FileOutputJob] = []

        for (offset, job) in jobs.enumerated() {
            guard mediaItems.contains(where: { $0.id == job.id }),
                  let timecode = job.timecode else {
                continue
            }

            analyzingItemID = job.id
            batchProgressMessage = "正在\(operationTitle) \(offset + 1) / \(jobs.count)"
            statusMessage = "正在\(operationTitle) \(job.sourceURL.lastPathComponent) -> \(job.destinationURL.lastPathComponent)"

            let scopedSourceAccess = job.sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scopedSourceAccess {
                    job.sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    if QuickTimeTMCDWriter.hasWritableTMCDTrack(in: job.sourceURL) {
                        try FileManager.default.copyItem(at: job.sourceURL, to: job.destinationURL)
                        return try QuickTimeTMCDWriter.writeStartTimecode(timecode, to: job.destinationURL)
                    }

                    return try await QuickTimeTMCDWriter.copyAddingStartTimecode(
                        timecode,
                        from: job.sourceURL,
                        to: job.destinationURL
                    )
                }.value

                successCount += 1
                successfulJobs.append(job)
                updateMediaItem(job.id) { item in
                    item.sourceMetadataStatus = "已输出 TMCD：\(report.newFirstFrame)"
                }
            } catch {
                try? FileManager.default.removeItem(at: job.destinationURL)
                failures.append((job.sourceURL.lastPathComponent, error.localizedDescription))
            }
        }

        let companionCSVFileName = renameOutputs
            ? writeRenamedCompanionCSVIfNeeded(
                successfulJobs: successfulJobs,
                destinationFolder: destinationFolder,
                failures: &failures
            )
            : nil

        finishFileOutput(
            operationTitle: operationTitle,
            successCount: successCount,
            failures: failures,
            companionCSVFileName: companionCSVFileName,
            successMessage: "已\(operationTitle) \(successCount) 个文件到 \(destinationFolder.lastPathComponent)"
        )
    }

    private func writeRenamedCompanionCSVIfNeeded(
        successfulJobs: [FileOutputJob],
        destinationFolder: URL,
        failures: inout [(fileName: String, message: String)]
    ) -> String? {
        guard exportsCompanionCSVForRenamedFiles, !successfulJobs.isEmpty else {
            return nil
        }

        let rows = successfulJobs.compactMap { job -> DaVinciMetadataCSVRow? in
            guard let item = mediaItems.first(where: { $0.id == job.id }) else {
                return nil
            }
            let metadata = exportMetadata(for: item)
            guard DaVinciMetadataCSVExporter.hasExportableMetadata(metadata) else {
                return nil
            }
            return DaVinciMetadataCSVRow(videoURL: job.destinationURL, metadata: metadata)
        }

        guard !rows.isEmpty else {
            return nil
        }

        batchProgressMessage = "正在生成配套 DaVinci CSV..."
        do {
            let csvData = try DaVinciMetadataCSVExporter.makeData(rows: rows)
            var usedFileNames = Set(successfulJobs.map { $0.destinationURL.lastPathComponent.lowercased() })
            let csvURL = uniqueDestinationURL(
                in: destinationFolder,
                stem: "Aquarius_DaVinci_Metadata_for_Renamed_Files",
                fileExtension: "csv",
                usedFileNames: &usedFileNames
            )
            try csvData.write(to: csvURL, options: .atomic)
            return csvURL.lastPathComponent
        } catch {
            failures.append(("配套 DaVinci CSV", error.localizedDescription))
            return nil
        }
    }

    private func finishFileOutput(
        operationTitle: String,
        successCount: Int,
        failures: [(fileName: String, message: String)],
        companionCSVFileName: String?,
        successMessage: String
    ) {
        analyzingItemID = nil
        let failedCount = failures.count
        let csvText = companionCSVFileName.map { "，CSV \($0)" } ?? ""
        batchProgressMessage = "\(operationTitle)完成：成功 \(successCount) 个，失败 \(failedCount) 个\(csvText)"

        if failures.isEmpty {
            errorMessage = nil
            statusMessage = successMessage + csvText
        } else {
            let failureText = failures
                .prefix(4)
                .map { "\($0.fileName)：\($0.message)" }
                .joined(separator: "\n")
            errorMessage = "\(operationTitle)失败 \(failedCount) 个：\n\(failureText)"
            statusMessage = "\(operationTitle)完成：成功 \(successCount) 个，失败 \(failedCount) 个"
        }
    }

    private func burnTimecodeIntoTMCD(jobs: [TimecodeBurnJob]) async {
        guard !jobs.isEmpty else {
            return
        }

        pausePlayback()
        isBurningTimecode = true
        errorMessage = nil
        batchProgressMessage = "准备烧录时间码..."
        defer {
            isBurningTimecode = false
            analyzingItemID = nil
        }

        var successCount = 0
        var failures: [(fileName: String, message: String)] = []

        for (offset, job) in jobs.enumerated() {
            guard mediaItems.contains(where: { $0.id == job.id }) else {
                continue
            }

            analyzingItemID = job.id
            batchProgressMessage = "正在烧录 \(offset + 1) / \(jobs.count)"
            statusMessage = "正在烧录 \(job.url.lastPathComponent)：\(job.timecode.description)"

            let scopedAccess = job.url.startAccessingSecurityScopedResource()
            defer {
                if scopedAccess {
                    job.url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try QuickTimeTMCDWriter.writeStartTimecode(job.timecode, to: job.url)
                }.value

                successCount += 1
                updateMediaItem(job.id) { item in
                    item.sourceTimecodeMetadata = QuickTimeTimecodeMetadata(
                        firstFrame: report.newFirstFrame,
                        lastFrame: report.newLastFrame,
                        frameRate: Double(report.newFrameRate),
                        frameQuanta: report.newFrameRate,
                        format: "tmcd"
                    )
                    item.sourceMetadataStatus = "TMCD 已写入：\(report.newFirstFrame)"
                }
            } catch {
                failures.append((job.url.lastPathComponent, error.localizedDescription))
            }
        }

        analyzingItemID = nil
        let failedCount = failures.count
        batchProgressMessage = "TMCD 烧录完成：成功 \(successCount) 个，失败 \(failedCount) 个"

        if failures.isEmpty {
            errorMessage = nil
            statusMessage = "已将时间码烧录进 \(successCount) 个文件的 TMCD 轨道"
        } else {
            let failureText = failures
                .prefix(4)
                .map { "\($0.fileName)：\($0.message)" }
                .joined(separator: "\n")
            errorMessage = "烧录失败 \(failedCount) 个：\n\(failureText)"
            statusMessage = "TMCD 烧录完成：成功 \(successCount) 个，失败 \(failedCount) 个"
        }
    }

    private func exportMetadata(for item: MediaQueueItem) -> ClipExportMetadata {
        let resultForFallback = item.result.flatMap { isAnalysisStale(item) ? nil : $0 }
        let manual = item.manualMetadata
        let roll = manual.trimmedRoll ?? resultForFallback?.roll
        let cameraID = manual.trimmedCameraID
            ?? ManualMetadataOverrides.cameraID(from: roll)
            ?? resultForFallback?.cameraID
        let manualTimecode = manualStartTimecode(for: item)
        let startTimecode = manual.trimmedStartTimecode == nil
            ? resultForFallback?.startTimecode
            : manualTimecode

        return ClipExportMetadata(
            duration: resultForFallback?.duration ?? item.result?.duration,
            clipName: manual.trimmedClipName ?? resultForFallback?.clipName,
            roll: roll,
            cameraID: cameraID,
            startTimecode: startTimecode
        )
    }

    private func manualStartTimecode(for item: MediaQueueItem) -> Timecode? {
        guard let value = item.manualMetadata.trimmedStartTimecode else {
            return nil
        }

        return Timecode.parse(value, fps: timecodeFrameRateForManualEntry(item))
    }

    private func timecodeFrameRateForManualEntry(_ item: MediaQueueItem) -> Int {
        if let fps = sourceTimecodeFrameRateSetting.fps {
            return fps
        }

        if let result = item.result, !isAnalysisStale(item) {
            return result.fps
        }

        if let metadataFPS = item.sourceTimecodeMetadata?.roundedFrameRate {
            return metadataFPS
        }

        if let result = item.result {
            return result.fps
        }

        return 24
    }

    private func runAnalysis(for id: MediaQueueItem.ID, regions: [OCRRegion], progressPrefix: String?) async {
        guard !regions.isEmpty else {
            errorMessage = "请至少开启一个识别字段"
            statusMessage = "无法开始：未开启识别字段"
            return
        }
        guard let item = mediaItems.first(where: { $0.id == id }) else {
            return
        }

        let url = item.url
        analyzingItemID = id
        updateMediaItem(id) { item in
            item.analysisStatus = .analyzing
            item.result = nil
            item.errorMessage = nil
        }
        statusMessage = "\(progressPrefix ?? "")正在识别 \(url.lastPathComponent)..."
        defer {
            analyzingItemID = nil
        }

        let scopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if scopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let frameRateSetting = self.sourceTimecodeFrameRateSetting
            let output = try await Task.detached(priority: .userInitiated) {
                try await OCRClipAnalyzer().analyze(
                    url: url,
                    regions: regions,
                    sourceTimecodeFrameRateSetting: frameRateSetting
                )
            }.value

            updateMediaItem(id) { item in
                item.result = output
                item.analysisStatus = MediaAnalysisStatus.status(for: output)
                item.errorMessage = nil
            }
            if selectedMediaItemID == id {
                playbackDuration = max(playbackDuration, output.duration)
            }
            statusMessage = "\(progressPrefix ?? "")完成 \(url.lastPathComponent)：\(output.statusTitle)，\(Int(output.confidence * 100))% 置信度"
        } catch {
            updateMediaItem(id) { item in
                item.analysisStatus = .failed
                item.result = nil
                item.errorMessage = error.localizedDescription
            }
            errorMessage = error.localizedDescription
            statusMessage = "\(progressPrefix ?? "")分析失败：\(url.lastPathComponent)"
        }
    }

    private func loadSelectedMediaForPreview() {
        guard let item = selectedMediaItem else {
            unloadCurrentVideo()
            return
        }

        player?.pause()
        removePlayerTimeObserver()
        previewImageTask?.cancel()
        playbackDurationTask?.cancel()
        releaseSecurityScopedAccess()

        isPlaying = false
        currentPlaybackSeconds = 0
        playbackDuration = 0
        errorMessage = nil
        previewDiagnosticMessage = nil
        previewImage = nil

        beginSecurityScopedAccess(for: item.url)

        let fileExists = FileManager.default.fileExists(atPath: item.url.path)
        guard fileExists else {
            player = nil
            let message = "文件不存在或 App 无法访问：\(item.url.path)"
            errorMessage = message
            previewDiagnosticMessage = message
            statusMessage = "载入失败：找不到文件"
            updateMediaItem(item.id) { item in
                item.analysisStatus = .failed
                item.errorMessage = message
            }
            return
        }

        loadSourceMetadataIfNeeded(for: item.id)

        statusMessage = "已选择 \(item.url.lastPathComponent)"
        let previewItemID = item.id
        let previewURL = item.url
        previewImageTask = Task { @MainActor [weak self] in
            do {
                let image = try await self?.makePreviewImage(for: previewURL)
                guard !Task.isCancelled,
                      self?.selectedMediaItemID == previewItemID else {
                    return
                }
                self?.previewImage = image
            } catch {
                guard !Task.isCancelled,
                      self?.selectedMediaItemID == previewItemID else {
                    return
                }
                let detail = "\(error.localizedDescription)\n\(previewURL.path)"
                self?.previewDiagnosticMessage = "预览取帧失败：\(detail)"
                self?.errorMessage = "预览取帧失败：\(error.localizedDescription)"
                self?.statusMessage = "已选择 \(previewURL.lastPathComponent)，但预览取帧失败"
            }
        }

        let asset = AVURLAsset(url: item.url)
        loadPlaybackDuration(from: asset)
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.isMuted = true
        player = newPlayer
        installPlaybackTimeObserver(for: newPlayer)
    }

    private func unloadCurrentVideo() {
        player?.pause()
        removePlayerTimeObserver()
        previewImageTask?.cancel()
        playbackDurationTask?.cancel()
        releaseSecurityScopedAccess()
        player = nil
        previewImage = nil
        isPlaying = false
        currentPlaybackSeconds = 0
        playbackDuration = 0
        previewDiagnosticMessage = nil
    }

    private func loadPlaybackDuration(from asset: AVAsset) {
        playbackDurationTask = Task { @MainActor [weak self] in
            do {
                let duration = try await asset.load(.duration)
                guard !Task.isCancelled else {
                    return
                }
                let seconds = duration.seconds
                self?.playbackDuration = seconds.isFinite ? max(seconds, 0) : 0
            } catch {
                self?.playbackDuration = 0
            }
        }
    }

    private func loadSourceMetadataIfNeeded(for id: MediaQueueItem.ID) {
        guard let item = mediaItems.first(where: { $0.id == id }),
              item.sourceMetadataStatus == "未读取",
              !item.isLoadingSourceMetadata else {
            return
        }

        updateMediaItem(id) { item in
            item.sourceMetadataStatus = "正在读取 mediainfo..."
            item.isLoadingSourceMetadata = true
        }

        sourceMetadataTasks[id]?.cancel()
        sourceMetadataTasks[id] = Task { @MainActor [weak self] in
            let snapshot = await MediaInfoMetadataReader.read(url: item.url)
            guard !Task.isCancelled else {
                return
            }

            self?.updateMediaItem(id) { item in
                item.sourceMetadataFields = snapshot.fields
                item.sourceMetadataStatus = snapshot.status
                item.sourceTimecodeMetadata = snapshot.timecodeMetadata
                item.isLoadingSourceMetadata = false
            }
            self?.sourceMetadataTasks[id] = nil
        }
    }

    private func installPlaybackTimeObserver(for player: AVPlayer) {
        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                let seconds = time.seconds
                if seconds.isFinite {
                    self?.currentPlaybackSeconds = max(seconds, 0)
                }
                self?.isPlaying = player?.rate != 0
            }
        }
    }

    private func removePlayerTimeObserver() {
        guard let playerTimeObserver else {
            return
        }
        player?.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
    }

    private func sampleURL(for sample: SampleVideo) -> URL? {
        Bundle.main.url(
            forResource: sample.resourceName,
            withExtension: sample.resourceExtension,
            subdirectory: "Samples"
        ) ?? Bundle.main.url(
            forResource: sample.resourceName,
            withExtension: sample.resourceExtension
        )
    }

    private func applyKnownSamplePreset(for url: URL) -> String? {
        guard let sample = sampleVideos.first(where: { $0.fileName == url.lastPathComponent }) else {
            return nil
        }
        applySampleRegions(sample.regions)
        return sample.displayName
    }

    private func applySampleRegions(_ sampleRegions: [OCRRegion]?) {
        guard let sampleRegions else {
            return
        }
        regions = sampleRegions
        selectedROIPresetID = nil
        selectFirstEnabledRegionIfNeeded()
    }

    private func selectFirstEnabledRegionIfNeeded() {
        if let selectedRegion = regions.first(where: { $0.id == selectedRegionID }),
           enabledFieldKinds.contains(selectedRegion.kind) {
            return
        }

        if let firstEnabledRegion = enabledRegions.first {
            selectedRegionID = firstEnabledRegion.id
        }
    }

    private func beginSecurityScopedAccess(for url: URL) {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        if didStartAccess {
            securityScopedURL = url
            isUsingSecurityScopedAccess = true
        } else {
            securityScopedURL = nil
            isUsingSecurityScopedAccess = false
        }
    }

    private func releaseSecurityScopedAccess() {
        if isUsingSecurityScopedAccess {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        isUsingSecurityScopedAccess = false
    }

    private func makePreviewImage(for url: URL) async throws -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.apertureMode = .encodedPixels

        var lastError: Error?
        for seconds in [1.0, 0.25, 0.0] {
            do {
                let frame = try await generator.ocrTimecodeCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600))
                let image = frame.image
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            } catch {
                lastError = error
            }
        }

        throw lastError ?? PreviewImageError.noFrame
    }

    private func videoURLs(in folderURL: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { value in
            guard let url = value as? URL,
                  Self.isSupportedVideoURL(url),
                  (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func isSupportedVideoURL(_ url: URL) -> Bool {
        supportedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func localizedMetadataLabel(for header: String) -> String {
        switch header {
        case "File Name":
            "文件名"
        case "Reel Number":
            "卷号"
        case "Camera #":
            "机位号"
        case "Start TC":
            "时间码"
        case "End TC":
            "结束时间码"
        case "Duration TC":
            "持续时间码"
        case "Start Frame":
            "起始帧"
        case "End Frame":
            "结束帧"
        case "Frames":
            "帧数"
        default:
            header
        }
    }

    private static let supportedVideoExtensions: Set<String> = [
        "mov",
        "mp4",
        "m4v",
        "mxf",
        "avi",
        "mkv",
        "mts",
        "m2ts",
        "mpg",
        "mpeg"
    ]

    private static var supportedVideoContentTypes: [UTType] {
        var identifiers = Set<String>()
        var types: [UTType] = []

        for type in [UTType.movie, .quickTimeMovie, .mpeg4Movie] {
            if identifiers.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        for fileExtension in supportedVideoExtensions.sorted() {
            guard let type = UTType(filenameExtension: fileExtension),
                  identifiers.insert(type.identifier).inserted else {
                continue
            }
            types.append(type)
        }

        return types
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func itemID(for url: URL) -> MediaQueueItem.ID? {
        let path = normalizedPath(url)
        return mediaItems.first { normalizedPath($0.url) == path }?.id
    }

    private func selectAdjacentMediaItem(offset: Int) {
        guard !mediaItems.isEmpty else {
            return
        }

        guard let selectedMediaItemID,
              let currentIndex = mediaItems.firstIndex(where: { $0.id == selectedMediaItemID }) else {
            selectMediaItem(mediaItems[0].id)
            return
        }

        let nextIndex = min(max(currentIndex + offset, mediaItems.startIndex), mediaItems.index(before: mediaItems.endIndex))
        guard nextIndex != currentIndex else {
            return
        }

        selectMediaItem(mediaItems[nextIndex].id)
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func updateMediaItem(_ id: MediaQueueItem.ID, mutate: (inout MediaQueueItem) -> Void) {
        guard let index = mediaItems.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&mediaItems[index])
    }

    func isAnalysisStale(_ item: MediaQueueItem) -> Bool {
        guard let result = item.result else {
            return false
        }
        return result.sourceTimecodeFrameRateSetting != sourceTimecodeFrameRateSetting
    }

    private func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "00:00"
        }

        let wholeSeconds = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    private func loadProjectOutputSettings() {
        guard let storeURL = projectOutputSettingsStoreURL,
              let data = try? Data(contentsOf: storeURL),
              let settings = try? JSONDecoder().decode(ProjectOutputSettings.self, from: data) else {
            return
        }

        isLoadingProjectOutputSettings = true
        isTimecodeBurnOptionEnabled = settings.isTimecodeBurnEnabled
        timecodeBurnOutputMode = settings.timecodeBurnOutputMode
        isFileRenameOptionEnabled = settings.isFileRenameEnabled
        exportsCompanionCSVForRenamedFiles = settings.exportsCompanionCSVForRenamedFiles
        showsTimecodeDiagnosticsDetails = settings.showsTimecodeDiagnosticsDetails
        renameOutputPrefix = settings.renamePrefix
        renameOutputSuffix = settings.renameSuffix
        isLoadingProjectOutputSettings = false
    }

    private func persistProjectOutputSettings() {
        guard !isLoadingProjectOutputSettings else {
            return
        }
        guard let storeURL = projectOutputSettingsStoreURL else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let settings = ProjectOutputSettings(
                isTimecodeBurnEnabled: isTimecodeBurnOptionEnabled,
                timecodeBurnOutputMode: timecodeBurnOutputMode,
                isFileRenameEnabled: isFileRenameOptionEnabled,
                exportsCompanionCSVForRenamedFiles: exportsCompanionCSVForRenamedFiles,
                showsTimecodeDiagnosticsDetails: showsTimecodeDiagnosticsDetails,
                renamePrefix: renameOutputPrefix,
                renameSuffix: renameOutputSuffix
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            errorMessage = "保存项目设置失败：\(error.localizedDescription)"
        }
    }

    private func loadROIPresets() {
        guard let storeURL = roiPresetStoreURL,
              let data = try? Data(contentsOf: storeURL),
              let presets = try? decodeROIPresets(from: data),
              !presets.isEmpty else {
            roiPresets = [Self.defaultROIPreset]
            selectedROIPresetID = roiPresets.first?.id
            regions = Self.defaultROIPreset.ocrRegions
            return
        }

        roiPresets = presets
        selectedROIPresetID = presets.first?.id
        if let firstPreset = presets.first {
            regions = firstPreset.ocrRegions
            selectFirstEnabledRegionIfNeeded()
        }
    }

    private func persistROIPresets() {
        guard let storeURL = roiPresetStoreURL else {
            errorMessage = "无法定位 ROI 预设保存目录"
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(roiPresets)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            errorMessage = "保存 ROI 预设失败：\(error.localizedDescription)"
        }
    }

    private func decodeROIPresets(from data: Data) throws -> [ROIPreset] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let presets = try? decoder.decode([ROIPreset].self, from: data) {
            return presets
        }
        return [try decoder.decode(ROIPreset.self, from: data)]
    }

    private func importedPreset(from preset: ROIPreset) -> ROIPreset {
        ROIPreset(
            id: roiPresets.contains(where: { $0.id == preset.id }) ? UUID() : preset.id,
            name: uniquePresetName(preset.name),
            regions: preset.ocrRegions,
            createdAt: preset.createdAt,
            updatedAt: Date()
        )
    }

    private func uniquePresetName(_ name: String, excluding excludedID: ROIPreset.ID? = nil) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? "ROI Preset" : trimmedName
        let existingNames = Set(
            roiPresets
                .filter { $0.id != excludedID }
                .map(\.name)
        )
        guard existingNames.contains(baseName) else {
            return baseName
        }

        var index = 2
        while existingNames.contains("\(baseName) \(index)") {
            index += 1
        }
        return "\(baseName) \(index)"
    }

    private static let applicationSupportFolderName = "Aquarius"
    private static let legacyApplicationSupportFolderName = "OCR" + "Timecode"

    private func migrateLegacyApplicationSupportIfNeeded() {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let storeURL = applicationSupportURL.appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent(Self.legacyApplicationSupportFolderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path),
              !FileManager.default.fileExists(atPath: storeURL.path) else {
            return
        }

        do {
            try FileManager.default.copyItem(at: legacyStoreURL, to: storeURL)
        } catch {
            errorMessage = "迁移旧版本设置失败：\(error.localizedDescription)"
        }
    }

    private var roiPresetStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("ROIPresets.json")
    }

    private var projectOutputSettingsStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Self.applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("ProjectOutputSettings.json")
    }

    private static let defaultROIPreset = ROIPreset(
        id: UUID(uuidString: "A6D078A1-E876-4790-941F-76DB6C0DD9C5") ?? UUID(),
        name: "QTake 左下默认",
        regions: OCRRegion.qtakeLowerLeftPreset,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    private func promptForText(
        title: String,
        message: String,
        defaultValue: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return textField.stringValue
    }

    private enum PreviewImageError: LocalizedError {
        case noFrame

        var errorDescription: String? {
            "没有从视频中取到可显示帧"
        }
    }
}

private extension DateFormatter {
    static let roiPresetName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter
    }()
}
