// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()
    @State private var isDropTargeted = false
    @State private var isShowingProjectSettings = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            HSplitView {
                mediaSidebar
                    .frame(minWidth: 270, idealWidth: 310, maxWidth: 380)

                HSplitView {
                    videoWorkspace
                        .frame(minWidth: 620)

                    inspector
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)
                }
            }

            Divider()
            sampleLog
                .frame(height: 180)
        }
        .frame(minWidth: 1360, minHeight: 920)
        .overlay(alignment: .topLeading) {
            mediaNavigationShortcuts
        }
        .overlay(alignment: .bottomTrailing) {
            projectSettingsLauncher
        }
        .sheet(isPresented: $isShowingProjectSettings) {
            ProjectSettingsView(viewModel: viewModel, isPresented: $isShowingProjectSettings)
        }
        .onAppear {
            if viewModel.mediaItems.isEmpty {
                viewModel.loadSample()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Aquarius")
                    .font(.title2.weight(.semibold))
                Text(viewModel.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                ForEach(viewModel.sampleVideos) { sample in
                    Button(sample.displayName) {
                        viewModel.loadSample(sample)
                    }
                }
            } label: {
                Label("载入样片", systemImage: "film")
            }

            Button {
                Task {
                    await viewModel.analyzeAllMediaItems()
                }
            } label: {
                Label(viewModel.isBatchAnalyzing ? "批量提取中" : "全部提取", systemImage: "text.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.mediaItems.isEmpty || viewModel.isAnalyzing || !viewModel.hasEnabledFields)

            Button {
                viewModel.exportDaVinciMetadataCSV()
            } label: {
                Label("导出 CSV", systemImage: "tablecells")
            }
            .disabled(!viewModel.canExportDaVinciMetadata || viewModel.isAnalyzing)

            if viewModel.shouldShowTimecodeBurnButton {
                Button {
                    viewModel.runTimecodeBurnAction()
                } label: {
                    Label(viewModel.isBurningTimecode ? "处理中" : "烧录时间码", systemImage: "timer")
                }
                .disabled(!viewModel.canBurnTimecodeIntoTMCD)
                .help(viewModel.timecodeBurnButtonHelp)
            }

            if viewModel.shouldShowFileRenameButton {
                Button {
                    viewModel.copyFilesWithMetadataNames()
                } label: {
                    Label("复制改名", systemImage: "textformat")
                }
                .disabled(!viewModel.canCopyFilesWithMetadataNames)
                .help("复制到新文件夹，并把输出文件名改为识别或手动写入的文件名")
            }

            if viewModel.shouldShowBurnAndRenameButton {
                Button {
                    viewModel.burnTimecodeAndRenameIntoNewFolder()
                } label: {
                    Label("烧录并改名", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canBurnAndRenameFiles)
                .help("复制到新文件夹，同时写入 TMCD 并改成元数据文件名")
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var mediaNavigationShortcuts: some View {
        HStack(spacing: 0) {
            Button {
                viewModel.selectPreviousMediaItem()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Button {
                viewModel.selectNextMediaItem()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.downArrow, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var projectSettingsLauncher: some View {
        Button {
            isShowingProjectSettings = true
        } label: {
            Label("项目设置", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .keyboardShortcut("p", modifiers: .command)
        .help("项目设置 (Command-P)")
        .padding(.trailing, 18)
        .padding(.bottom, 16)
    }

    private var mediaSidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("媒体库")
                            .font(.headline)
                        Text("\(viewModel.mediaItems.count) 个视频")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        viewModel.clearAllAnalysisResults()
                    } label: {
                        Label("清除提取", systemImage: "arrow.counterclockwise")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(!viewModel.hasAnalysisRecords || viewModel.isAnalyzing)
                    .help("清除全部提取结果")

                    Button {
                        viewModel.clearMediaList()
                    } label: {
                        Label("清空", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(viewModel.mediaItems.isEmpty || viewModel.isAnalyzing)
                    .help("清空列表")
                }

                HStack(spacing: 8) {
                    Button {
                        viewModel.promptImportMediaFiles()
                    } label: {
                        Label("文件", systemImage: "plus")
                    }
                    .disabled(viewModel.isAnalyzing)

                    Button {
                        viewModel.promptImportMediaFolder()
                    } label: {
                        Label("文件夹", systemImage: "folder.badge.plus")
                    }
                    .disabled(viewModel.isAnalyzing)
                }

            }
            .buttonStyle(.bordered)
            .padding(14)

            Divider()

            if viewModel.mediaItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("导入 Qtake 视频文件夹")
                        .font(.callout.weight(.medium))
                    Text("左侧列表会保存待提取素材，导出时只包含列表中仍保留的视频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.mediaItems) { item in
                            MediaQueueRow(
                                item: item,
                                isSelected: item.id == viewModel.selectedMediaItemID,
                                isAnalyzing: item.id == viewModel.analyzingItemID,
                                isStale: viewModel.isAnalysisStale(item),
                                canRunActions: !viewModel.isAnalyzing,
                                canClearAnalysis: item.result != nil || item.errorMessage != nil || item.analysisStatus != .pending,
                                onSelect: {
                                    viewModel.selectMediaItem(item.id)
                                },
                                onAnalyze: {
                                    Task {
                                        await viewModel.analyzeMediaItem(id: item.id)
                                    }
                                },
                                onClearAnalysis: {
                                    viewModel.clearAnalysisResult(id: item.id)
                                },
                                onDelete: {
                                    viewModel.removeMediaItem(item.id)
                                }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(8)
                    .overlay {
                        Label("松开添加素材", systemImage: "tray.and.arrow.down")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.addDroppedURLs(urls)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
    }

    private var videoWorkspace: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))

                if viewModel.player != nil || viewModel.previewImage != nil {
                    videoCanvas
                        .padding(18)
                } else {
                    Text("未载入视频")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button {
                        viewModel.seekToStart()
                    } label: {
                        Label("开头", systemImage: "backward.end")
                    }

                    Button {
                        viewModel.shuttleBackward()
                    } label: {
                        Label("倒放", systemImage: "backward.fill")
                            .labelStyle(.iconOnly)
                    }
                    .keyboardShortcut("j", modifiers: [])
                    .help("J")

                    Button {
                        viewModel.pausePlayback()
                    } label: {
                        Label("暂停", systemImage: "pause.fill")
                            .labelStyle(.iconOnly)
                    }
                    .keyboardShortcut("k", modifiers: [])
                    .help("K")

                    Button {
                        viewModel.shuttleForward()
                    } label: {
                        Label("播放", systemImage: "forward.fill")
                            .labelStyle(.iconOnly)
                    }
                    .keyboardShortcut("l", modifiers: [])
                    .help("L")

                    Button {
                        viewModel.seekToEnd()
                    } label: {
                        Label("结尾", systemImage: "forward.end")
                    }

                    Button {
                        viewModel.playOrPause()
                    } label: {
                        EmptyView()
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)

                    Slider(
                        value: Binding(
                            get: { viewModel.currentPlaybackSeconds },
                            set: { viewModel.seek(to: $0) }
                        ),
                        in: 0...max(viewModel.playbackDuration, 0.1)
                    )
                    .disabled(viewModel.player == nil || viewModel.playbackDuration <= 0)
                    .frame(minWidth: 180, maxWidth: .infinity)

                    Text(viewModel.playbackPositionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .trailing)

                    CurrentFrameBadge(
                        timecode: viewModel.currentSourceTimecodeText,
                        frame: viewModel.currentFrameText
                    )
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var videoCanvas: some View {
        ZStack {
            if let previewImage = viewModel.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
            }

            if viewModel.player != nil {
                PlayerLayerView(player: viewModel.player)
            }

            ROIEditorOverlay(
                regions: viewModel.regions,
                selectedRegionID: viewModel.selectedRegionID,
                enabledFieldKinds: viewModel.enabledFieldKinds
            ) { normalizedRect in
                viewModel.updateSelectedRegion(to: normalizedRect)
            }

            if !viewModel.isPlaying, let diagnostic = viewModel.previewDiagnosticMessage {
                PreviewDiagnosticOverlay(message: diagnostic)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("素材")
                        .font(.headline)
                    Text(viewModel.selectedVideoURL?.lastPathComponent ?? "未选择")
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("识别结果")
                        .font(.headline)
                    Spacer()
                    if let result = viewModel.result {
                        StatusBadge(title: result.statusTitle, confidence: result.confidence)
                    }
                }

                if let result = viewModel.result {
                    ResultRow(title: "时间码", value: viewModel.selectedEffectiveStartTimecode?.description ?? (viewModel.isFieldEnabled(.timecode) ? "需复核" : "未开启"))
                    ResultRow(title: "文件名", value: viewModel.selectedEffectiveClipName ?? (viewModel.isFieldEnabled(.clipName) ? "需复核" : "未开启"))
                    ResultRow(title: "卷号", value: viewModel.selectedEffectiveRoll ?? (viewModel.isFieldEnabled(.roll) ? "需复核" : "未开启"))
                    ResultRow(title: "机位号", value: viewModel.selectedEffectiveCameraID ?? (viewModel.isFieldEnabled(.roll) ? "需复核" : "未开启"))
                    ResultRow(title: "视频帧率", value: String(format: "%.3f fps", result.videoFrameRate))
                    ResultRow(title: "源TC帧率", value: result.timecodeDiagnostics?.sourceFrameRateDisplay ?? "\(result.fps)")
                    ResultRow(title: "Duration", value: String(format: "%.2fs", result.duration))

                    if viewModel.selectedHasManualMetadataOverrides {
                        Label("已应用手动元数据覆盖", systemImage: "pencil")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }

                    if viewModel.selectedResultIsStale {
                        Label("源时间码帧率设置已改变，需重新提取", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !result.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(result.notes, id: \.self) { note in
                                Label(note, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.top, 4)
                    }
                } else if viewModel.selectedHasManualMetadataOverrides {
                    ResultRow(title: "时间码", value: viewModel.selectedEffectiveStartTimecode?.description ?? "未设置")
                    ResultRow(title: "文件名", value: viewModel.selectedEffectiveClipName ?? "未设置")
                    ResultRow(title: "卷号", value: viewModel.selectedEffectiveRoll ?? "未设置")
                    ResultRow(title: "机位号", value: viewModel.selectedEffectiveCameraID ?? "未设置")

                    Label("当前显示手动录入元数据，尚未 OCR 提取", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.blue)

                    if let error = viewModel.selectedManualStartTimecodeError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("等待识别")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            timecodeSettingsAndDiagnostics

            Divider()

            metadataEditor

            Divider()

            metadataComparison

            Divider()

            fieldToggles

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("检测区域")
                        .font(.headline)
                    Spacer()
                    Button {
                        viewModel.resetRegionsToPreset()
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Picker(
                        "ROI 预设",
                        selection: Binding<ROIPreset.ID?>(
                            get: { viewModel.selectedROIPresetID },
                            set: { presetID in
                                performAfterViewUpdate {
                                    if let presetID {
                                        viewModel.applyROIPreset(presetID)
                                    } else {
                                        viewModel.selectedROIPresetID = nil
                                    }
                                }
                            }
                        )
                    ) {
                        Text("未选择").tag(Optional<ROIPreset.ID>.none)
                        ForEach(viewModel.roiPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .labelsHidden()

                    HStack(spacing: 6) {
                        Button {
                            viewModel.promptSaveCurrentROIPreset()
                        } label: {
                            Label("保存", systemImage: "plus")
                                .labelStyle(.iconOnly)
                        }
                        .help("保存当前 ROI 为预设")

                        Button {
                            viewModel.promptRenameSelectedROIPreset()
                        } label: {
                            Label("重命名", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                        }
                        .help("重命名当前 ROI 预设")
                        .disabled(viewModel.selectedROIPresetID == nil)

                        Button {
                            viewModel.deleteSelectedROIPreset()
                        } label: {
                            Label("删除", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .help("删除当前 ROI 预设")
                        .disabled(viewModel.selectedROIPresetID == nil)

                        Spacer()

                        Button {
                            viewModel.importROIPresets()
                        } label: {
                            Label("导入", systemImage: "square.and.arrow.down")
                                .labelStyle(.iconOnly)
                        }
                        .help("导入 ROI JSON")

                        Button {
                            viewModel.exportSelectedROIPreset()
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                        }
                        .help("导出当前 ROI JSON")
                        .disabled(viewModel.selectedROIPresetID == nil)
                    }
                    .buttonStyle(.bordered)
                }

                ForEach(viewModel.regions) { region in
                    let isEnabled = viewModel.isFieldEnabled(region.kind)
                    Button {
                        viewModel.selectedRegionID = region.id
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(for: region.kind))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(region.kind.title)
                                    .font(.callout.weight(.medium))
                                Text(regionSummary(region))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if viewModel.selectedRegionID == region.id && isEnabled {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .padding(8)
                    .background(
                        viewModel.selectedRegionID == region.id && isEnabled
                            ? Color.accentColor.opacity(0.15)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .opacity(isEnabled ? 1 : 0.42)
                }
            }

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "xmark.octagon")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let diagnostic = viewModel.previewDiagnosticMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("预览诊断", systemImage: "waveform.path.ecg")
                            .font(.callout.weight(.semibold))
                        Text(diagnostic)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var metadataComparison: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("元数据对比")
                .font(.headline)
                Spacer()
                if viewModel.isLoadingSourceMetadata {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            MetadataFieldGroup(
                title: "当前文件",
                fields: viewModel.sourceMetadataFields,
                emptyText: viewModel.sourceMetadataStatus
            )

            MetadataFieldGroup(
                title: "识别后导出",
                fields: viewModel.updatedMetadataFields,
                emptyText: viewModel.selectedResultIsStale
                    ? "源时间码帧率设置已改变；可重新提取或手动覆盖导出字段"
                    : (viewModel.result == nil ? "等待 OCR 识别或手动录入" : "没有可导出元数据")
            )
        }
    }

    private var metadataEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("元数据编辑")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.clearSelectedManualMetadata()
                } label: {
                    Label("清除当前", systemImage: "eraser")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("清除当前片段的手动元数据覆盖")
                .disabled(!viewModel.selectedHasManualMetadataOverrides || viewModel.selectedMediaItem == nil)
            }

            if viewModel.selectedMediaItem == nil {
                Text("请选择一个素材后编辑元数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前片段")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MetadataEditTextFieldRow(
                        title: "文件名",
                        placeholder: viewModel.result?.clipName ?? "手动输入识别文件名",
                        text: Binding(
                            get: { viewModel.selectedManualClipName },
                            set: { viewModel.setSelectedManualClipName($0) }
                        )
                    )

                    MetadataEditTextFieldRow(
                        title: "起始TC",
                        placeholder: viewModel.result?.startTimecode?.description ?? "HH:MM:SS:FF",
                        monospaced: true,
                        text: Binding(
                            get: { viewModel.selectedManualStartTimecode },
                            set: { viewModel.setSelectedManualStartTimecode($0) }
                        )
                    )

                    Text("起始 TC 按 \(viewModel.selectedManualTimecodeFrameRate) 解析；CSV 匹配仍使用媒体原始文件名。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = viewModel.selectedManualStartTimecodeError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("当前列表")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        MetadataEditTextFieldRow(
                            title: "卷号",
                            placeholder: viewModel.selectedEffectiveRoll ?? "A001 / A_0001_12SQ",
                            text: $viewModel.listRollOverrideDraft
                        )

                        Button {
                            viewModel.applyListRollOverride()
                        } label: {
                            Label("应用卷号", systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                        }
                        .help("将卷号应用到当前列表；留空应用会清除手动卷号覆盖")
                        .disabled(viewModel.mediaItems.isEmpty || viewModel.isAnalyzing)
                    }

                    HStack(spacing: 8) {
                        MetadataEditTextFieldRow(
                            title: "机位号",
                            placeholder: viewModel.selectedEffectiveCameraID ?? "A / A_",
                            text: $viewModel.listCameraIDOverrideDraft
                        )

                        Button {
                            viewModel.applyListCameraIDOverride()
                        } label: {
                            Label("应用机位号", systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                        }
                        .help("将机位号应用到当前列表；留空应用会清除手动机位号覆盖")
                        .disabled(viewModel.mediaItems.isEmpty || viewModel.isAnalyzing)
                    }

                    Text("适合成卷导入后统一写入卷号和机位号；单片段文件名和起始 TC 只影响当前选中素材。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var timecodeSettingsAndDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("时间码设置")
                .font(.headline)

            Picker(
                "源时间码帧率",
                selection: Binding(
                    get: { viewModel.sourceTimecodeFrameRateSetting },
                    set: { setting in
                        performAfterViewUpdate {
                            viewModel.setSourceTimecodeFrameRateSetting(setting)
                        }
                    }
                )
            ) {
                ForEach(SourceTimecodeFrameRateSetting.allCases) { setting in
                    Text(setting.title).tag(setting)
                }
            }
            .pickerStyle(.menu)

            Text("应用于整个列表；修改后已有结果需重新提取。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.showsTimecodeDiagnosticsDetails {
                timecodeDiagnosticsDetails
            } else if let result = viewModel.result,
                      let diagnostics = result.timecodeDiagnostics,
                      diagnostics.status != .consistent,
                      diagnostics.status != .notChecked {
                Label(diagnostics.status.title, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(color(for: diagnostics.status))
            }
        }
    }

    private var timecodeDiagnosticsDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = viewModel.result {
                ResultRow(title: "视频帧率", value: String(format: "%.3f fps", result.videoFrameRate))
                ResultRow(title: "源TC帧率", value: result.timecodeDiagnostics?.sourceFrameRateDisplay ?? "\(result.fps)")
                ResultRow(title: "当前TMCD", value: viewModel.selectedTimecodeMetadata?.displayText ?? "未检测到")

                if let diagnostics = result.timecodeDiagnostics {
                    HStack(alignment: .firstTextBaseline) {
                        Text("一致性")
                            .foregroundStyle(.secondary)
                            .frame(width: 82, alignment: .leading)
                        Text(diagnostics.status.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(color(for: diagnostics.status))
                        Spacer()
                    }

                    ResultRow(title: "漂移", value: diagnostics.driftDisplay)

                    if let tmcdComparison = tmcdComparison(for: result) {
                        Label(tmcdComparison.text, systemImage: tmcdComparison.systemImage)
                            .font(.caption)
                            .foregroundStyle(tmcdComparison.color)
                    }

                    ForEach(diagnostics.notes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else if viewModel.isFieldEnabled(.timecode) {
                    Text("等待 OCR 后检测时间码帧率与漂移")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("时间码字段未开启")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("等待 OCR 后显示检测结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("自动仅推断 24/25/30；23.976 和 29.97 需手动指定。29.97 DF 请使用分号时间码。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var fieldToggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("识别字段")
                .font(.headline)

            ForEach(OCRFieldKind.allCases) { kind in
                fieldToggleRow(for: kind)
            }

            if !viewModel.hasEnabledFields {
                Label("至少开启一个字段", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func fieldToggleRow(for kind: OCRFieldKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: kind))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .center)

            Text(kind.title)
                .font(.callout.weight(.semibold))
                .frame(width: 62, alignment: .leading)

            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.isFieldEnabled(kind) },
                    set: { isEnabled in
                        performAfterViewUpdate {
                            viewModel.setField(kind, isEnabled: isEnabled)
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .fixedSize()
            .frame(width: 72, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sampleLog: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let samples = viewModel.result?.samples, !samples.isEmpty {
                        ForEach(samples) { sample in
                            HStack(alignment: .top, spacing: 10) {
                                Text(sample.region.kind.title)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(color(for: sample.region.kind))
                                    .frame(width: 86, alignment: .leading)
                                Text(String(format: "%.2fs", sample.actualSeconds))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                                Text("\(Int(sample.confidence * 100))%")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 42, alignment: .trailing)
                                Text(sampleDeviationText(sample))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(sampleDeviationColor(sample))
                                    .frame(width: 54, alignment: .trailing)
                                Text(sample.rawText.isEmpty ? "未识别" : sample.rawText.replacingOccurrences(of: "\n", with: " / "))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                    } else {
                        Text("暂无样本")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 28)
            }
            .padding(.trailing, 44)

            HStack {
                Text("OCR 样本")
                    .font(.headline)
                Spacer()
                if let count = viewModel.result?.samples.count {
                    Text("\(count) 个样本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func regionSummary(_ region: OCRRegion) -> String {
        let rect = region.normalizedRect
        return String(
            format: "%@  x %.0f%%  y %.0f%%  w %.0f%%  h %.0f%%",
            region.kind.title,
            rect.minX * 100,
            rect.minY * 100,
            rect.width * 100,
            rect.height * 100
        )
    }

    private func color(for kind: OCRFieldKind) -> Color {
        switch kind {
        case .clipName:
            .cyan
        case .roll:
            .orange
        case .timecode:
            .green
        }
    }

    private func color(for status: TimecodeConsistencyStatus) -> Color {
        switch status {
        case .notChecked:
            .secondary
        case .consistent:
            .green
        case .frameRateMismatchStable:
            .yellow
        case .driftSuspected:
            .orange
        case .highRisk:
            .red
        }
    }

    private func tmcdComparison(for result: ClipOCRResult) -> (text: String, color: Color, systemImage: String)? {
        guard let metadata = viewModel.selectedTimecodeMetadata else {
            return nil
        }

        guard let startTimecode = result.startTimecode else {
            return ("当前文件有 TMCD，但 OCR 未稳定识别画面时间码", .orange, "exclamationmark.triangle")
        }

        let timecodeMatches = metadata.firstFrame == nil || metadata.firstFrame == startTimecode.description
        let frameRateMatches = metadata.roundedFrameRate == nil || metadata.roundedFrameRate == startTimecode.fps

        if timecodeMatches && frameRateMatches {
            return ("TMCD 与画面 OCR 一致", .green, "checkmark.circle")
        }

        return ("TMCD 与画面 OCR 不一致", .orange, "exclamationmark.triangle")
    }

    private func sampleDeviationText(_ sample: OCRSample) -> String {
        guard sample.region.kind == .timecode else {
            return ""
        }

        switch sample.timecodeSampleStatus {
        case .notApplicable:
            return ""
        case .invalid:
            return "无效"
        case .jump:
            return "跳变"
        case .clustered, .deviated:
            guard let offset = sample.timecodeFrameOffset else {
                return sample.timecodeSampleStatus.title
            }
            return String(format: "%+d 帧", offset)
        }
    }

    private func sampleDeviationColor(_ sample: OCRSample) -> Color {
        switch sample.timecodeSampleStatus {
        case .notApplicable:
            return .secondary
        case .clustered:
            return .green
        case .deviated:
            return .orange
        case .jump, .invalid:
            return .red
        }
    }

    private func icon(for kind: OCRFieldKind) -> String {
        switch kind {
        case .clipName:
            "doc.text"
        case .roll:
            "film"
        case .timecode:
            "timer"
        }
    }

    private func performAfterViewUpdate(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            action()
        }
    }
}

private struct ProjectSettingsView: View {
    @ObservedObject var viewModel: AnalysisViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("项目设置")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    settingsSection(title: "时间码显示") {
                        Toggle("显示时间码检测详情", isOn: $viewModel.showsTimecodeDiagnosticsDetails)

                        Text("关闭时右侧只保留源时间码帧率控制；检测到帧率不一致或高风险时仍会显示简短提示。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection(title: "时间码烧录") {
                        Toggle("启用时间码烧录按钮", isOn: $viewModel.isTimecodeBurnOptionEnabled)

                        Picker("输出方式", selection: $viewModel.timecodeBurnOutputMode) {
                            ForEach(TimecodeBurnOutputMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .disabled(!viewModel.isTimecodeBurnOptionEnabled)

                        Text(viewModel.timecodeBurnOutputMode.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection(title: "文件名改名") {
                        Toggle("启用复制改名按钮", isOn: $viewModel.isFileRenameOptionEnabled)

                        Toggle("复制改名后自动生成配套 DaVinci CSV", isOn: $viewModel.exportsCompanionCSVForRenamedFiles)
                            .disabled(!viewModel.isFileRenameOptionEnabled)

                        HStack(spacing: 10) {
                            TextField("前缀", text: $viewModel.renameOutputPrefix)
                                .textFieldStyle(.roundedBorder)
                            TextField("后缀", text: $viewModel.renameOutputSuffix)
                                .textFieldStyle(.roundedBorder)
                        }
                        .disabled(!viewModel.isFileRenameOptionEnabled)

                        Text("改名会复制到新文件夹，不修改源文件；文件名来自识别结果或手动输入，同名会自动附加 -1、-2。配套 CSV 会使用改名后的真实文件名作为 Resolve 匹配键。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection(title: "快捷键") {
                        HStack {
                            Text("打开项目设置")
                            Spacer()
                            Text("Command-P")
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 540, height: 520)
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct MediaQueueRow: View {
    let item: MediaQueueItem
    let isSelected: Bool
    let isAnalyzing: Bool
    let isStale: Bool
    let canRunActions: Bool
    let canClearAnalysis: Bool
    let onSelect: () -> Void
    let onAnalyze: () -> Void
    let onClearAnalysis: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 8) {
                    statusSymbol
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(displayPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(summaryText)
                            .font(.caption)
                            .foregroundStyle(summaryColor)
                            .lineLimit(2)

                        if let riskBadgeText {
                            Text(riskBadgeText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(riskBadgeColor.opacity(0.14))
                                .foregroundStyle(riskBadgeColor)
                                .clipShape(Capsule())
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                Button(action: onAnalyze) {
                    Label("提取", systemImage: "text.viewfinder")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canRunActions)
                .help("提取此素材")

                Button(action: onClearAnalysis) {
                    Label("清除提取", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canRunActions || !canClearAnalysis)
                .help("清除提取结果")

                Button(action: onDelete) {
                    Label("删除", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canRunActions)
                .help("从列表删除")
            }
            .buttonStyle(.borderless)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.48) : Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var statusSymbol: some View {
        ZStack {
            if isAnalyzing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: item.analysisStatus.systemImage)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var displayPath: String {
        item.directoryPath
            .replacingOccurrences(of: "/", with: "/\u{200B}")
            .replacingOccurrences(of: "_", with: "_\u{200B}")
            .replacingOccurrences(of: "-", with: "-\u{200B}")
    }

    private var summaryText: String {
        if isStale {
            return "设置已改变，需重新提取"
        }

        if let result = item.result {
            let tc = item.manualMetadata.trimmedStartTimecode ?? result.startTimecode?.description ?? "时间码 --"
            let roll = item.manualMetadata.trimmedRoll ?? result.roll ?? "卷号 --"
            let manualText = item.manualMetadata.hasAnyOverride ? "  手动" : ""
            return "\(item.analysisStatus.title)  \(tc)  \(roll)\(manualText)"
        }

        if item.manualMetadata.hasAnyOverride {
            let tc = item.manualMetadata.trimmedStartTimecode ?? "时间码 --"
            let roll = item.manualMetadata.trimmedRoll ?? "卷号 --"
            return "手动  \(tc)  \(roll)"
        }

        if let errorMessage = item.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        return item.analysisStatus.title
    }

    private var statusColor: Color {
        switch item.analysisStatus {
        case .pending:
            .secondary
        case .analyzing:
            .accentColor
        case .trusted:
            .green
        case .needsReview:
            .orange
        case .failed:
            .red
        }
    }

    private var summaryColor: Color {
        if isStale {
            return .orange
        }
        return item.analysisStatus == .failed ? .red : .secondary
    }

    private var riskBadgeText: String? {
        guard !isStale, let status = item.result?.timecodeDiagnostics?.status else {
            return isStale ? "需重提" : nil
        }

        switch status {
        case .notChecked:
            return nil
        case .consistent, .frameRateMismatchStable, .driftSuspected, .highRisk:
            return status.title
        }
    }

    private var riskBadgeColor: Color {
        if isStale {
            return .orange
        }

        switch item.result?.timecodeDiagnostics?.status {
        case .consistent:
            return .green
        case .frameRateMismatchStable:
            return .yellow
        case .driftSuspected:
            return .orange
        case .highRisk:
            return .red
        case .notChecked, .none:
            return .secondary
        }
    }
}

private struct MetadataFieldGroup: View {
    let title: String
    let fields: [MetadataField]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if fields.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    MetadataFieldRow(field: field)
                }
            }
        }
    }
}

private struct MetadataEditTextFieldRow: View {
    let title: String
    let placeholder: String
    var monospaced = false
    @Binding var text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            TextField(placeholder, text: $text)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
        }
    }
}

private struct MetadataFieldRow: View {
    let field: MetadataField

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(field.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            Text(displayValue)
                .font(.caption.monospaced())
                .lineLimit(isPath ? 5 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var isPath: Bool {
        field.label == "Path"
    }

    private var displayValue: String {
        guard isPath else {
            return field.value
        }

        return field.value
            .replacingOccurrences(of: "/", with: "/\u{200B}")
            .replacingOccurrences(of: "_", with: "_\u{200B}")
            .replacingOccurrences(of: "-", with: "-\u{200B}")
    }
}

private struct PreviewDiagnosticOverlay: View {
    let message: String

    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Label("预览不可用", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .lineLimit(3)
                }
                .padding(10)
                .background(.black.opacity(0.72))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Spacer()
            }

            Spacer()
        }
        .padding(12)
    }
}

private struct ROIEditorOverlay: View {
    let regions: [OCRRegion]
    let selectedRegionID: String
    let enabledFieldKinds: Set<OCRFieldKind>
    let onRectChanged: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(regions) { region in
                    let rect = overlayRect(for: region.normalizedRect, in: proxy.size)
                    let isEnabled = enabledFieldKinds.contains(region.kind)
                    let isSelected = region.id == selectedRegionID && isEnabled
                    let borderColor = isEnabled ? color(for: region.kind) : Color.white.opacity(0.35)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEnabled ? color(for: region.kind).opacity(isSelected ? 0.035 : 0.012) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    borderColor,
                                    style: StrokeStyle(lineWidth: isSelected ? 3 : 1.25, dash: isEnabled ? [] : [5, 4])
                                )
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.10), radius: 0, x: 0, y: 1)
                        .opacity(isEnabled ? 1 : 0.45)

                    if isSelected {
                        selectedRegionLabel(region.kind.title, rect: rect, canvasSize: proxy.size)

                        ForEach(Array(handlePoints(for: rect).enumerated()), id: \.offset) { _, point in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                                .frame(width: 8, height: 8)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 2)
                                        .strokeBorder(color(for: region.kind), lineWidth: 2)
                                }
                                .position(point)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        onRectChanged(normalizedRect(from: value.startLocation, to: value.location, in: proxy.size))
                    }
            )
        }
    }

    private func selectedRegionLabel(_ label: String, rect: CGRect, canvasSize: CGSize) -> some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.58))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .position(
                x: min(max(rect.minX + 38, 38), max(38, canvasSize.width - 38)),
                y: labelY(for: rect, canvasHeight: canvasSize.height)
            )
    }

    private func labelY(for rect: CGRect, canvasHeight: CGFloat) -> CGFloat {
        if rect.minY > 26 {
            return rect.minY - 13
        }

        return min(canvasHeight - 13, rect.maxY + 13)
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return .zero
        }

        let minX = min(start.x, end.x) / size.width
        let minY = min(start.y, end.y) / size.height
        let maxX = max(start.x, end.x) / size.width
        let maxY = max(start.y, end.y) / size.height
        let rect = CGRect(
            x: min(max(minX, 0), 1),
            y: min(max(minY, 0), 1),
            width: min(max(maxX - minX, 0.012), 1),
            height: min(max(maxY - minY, 0.012), 1)
        )

        return rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func overlayRect(for normalizedRect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * size.width,
            y: normalizedRect.minY * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        )
    }

    private func color(for kind: OCRFieldKind) -> Color {
        switch kind {
        case .clipName:
            .cyan
        case .roll:
            .orange
        case .timecode:
            .green
        }
    }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerHostView {
        PlayerLayerHostView()
    }

    func updateNSView(_ nsView: PlayerLayerHostView, context: Context) {
        nsView.player = player
    }
}

private final class PlayerLayerHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct ResultRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer()
        }
    }
}

private struct CurrentFrameBadge: View {
    let timecode: String
    let frame: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("当前时间码")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timecode)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("F\(frame)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 150, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct StatusBadge: View {
    let title: String
    let confidence: Double

    var body: some View {
        Text("\(title) \(Int(confidence * 100))%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        if confidence >= 0.82 {
            .green
        } else if confidence >= 0.45 {
            .orange
        } else {
            .red
        }
    }
}

#Preview {
    ContentView()
}
