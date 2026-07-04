import AppKit
import AVKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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

    private var securityScopedURL: URL?
    private var isUsingSecurityScopedAccess = false
    private var playerTimeObserver: Any?
    private var playbackDurationTask: Task<Void, Never>?
    private var sourceMetadataTasks: [MediaQueueItem.ID: Task<Void, Never>] = [:]

    init() {
        loadROIPresets()
    }

    deinit {
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
        analyzingItemID != nil || isBatchAnalyzing
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
        savePanel.nameFieldStringValue = "OCRTimecode_DaVinci_Metadata.csv"

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

    private var currentFrameOffset: Int {
        let fps = selectedMediaItem.map(timecodeFrameRateForManualEntry) ?? 24
        return max(0, Int(floor(currentPlaybackSeconds * Double(fps))))
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
                try OCRClipAnalyzer().analyze(
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

        do {
            previewImage = try makePreviewImage(for: item.url)
            statusMessage = "已选择 \(item.url.lastPathComponent)"
        } catch {
            let detail = "\(error.localizedDescription)\n\(item.url.path)"
            previewDiagnosticMessage = "预览取帧失败：\(detail)"
            errorMessage = "预览取帧失败：\(error.localizedDescription)"
            statusMessage = "已选择 \(item.url.lastPathComponent)，但预览取帧失败"
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

    private func makePreviewImage(for url: URL) throws -> NSImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.apertureMode = .encodedPixels

        var lastError: Error?
        for seconds in [1.0, 0.25, 0.0] {
            do {
                let image = try generator.copyCGImage(
                    at: CMTime(seconds: seconds, preferredTimescale: 600),
                    actualTime: nil
                )
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

    private var roiPresetStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("OCRTimecode", isDirectory: true)
            .appendingPathComponent("ROIPresets.json")
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
