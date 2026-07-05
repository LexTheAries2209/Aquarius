# OCRTimecode

OCRTimecode is a macOS SwiftUI utility for extracting burned-in clip metadata from video files. It samples video frames, runs Apple Vision OCR on configurable regions, resolves clip name, reel number, and source timecode, then helps prepare metadata for DaVinci Resolve or write the recovered start timecode back into QuickTime TMCD metadata.

OCRTimecode 是一个 macOS SwiftUI 工具，用于从视频画面上的烧录信息中提取素材元数据。它会抽样读取视频帧，在可调整的 ROI 区域内使用 Apple Vision OCR 识别文件名、卷号和源时间码，并辅助导出 DaVinci Resolve 元数据 CSV，或把识别出的起始时间码写回 QuickTime TMCD 元数据。

## 中文说明

### 适用场景

- QTake、现场监看或 dailies 视频已经把文件名、卷号、时间码烧在画面上。
- 原始文件缺少可靠的 QuickTime timecode track，或 Resolve 中需要批量补充 Reel / Camera / Start TC。
- 需要先 OCR 识别、人工复核，再导出 CSV 或生成带正确文件名和时间码的新文件。

### 主要功能

- 导入单个视频、多个视频、文件夹，或直接拖拽素材到窗口。
- 使用可视化 ROI 框选择需要 OCR 的区域，支持保存、重命名、导入和导出 ROI JSON 预设。
- 支持识别文件名、卷号、时间码三个字段，并可按需关闭其中某些字段。
- 自动抽样多帧并做一致性判断，显示可信、需复核或失败状态。
- 检测源时间码帧率，支持自动、24、25、30 fps；可提示视频帧率与源 TC 帧率不一致、疑似漂移或高风险结果。
- 读取现有文件元数据；如果系统安装了 `mediainfo`，会显示更完整的容器、编码、帧率、时长和当前 timecode 信息。
- 手动覆盖当前素材的文件名、起始 TC，以及对当前列表批量覆盖卷号、机位号。
- 导出 DaVinci Resolve 可导入的元数据 CSV。
- 可选把起始时间码写入 QuickTime TMCD 轨道，或复制到新文件夹后写入 TMCD。
- 可选按识别或手动输入的文件名复制改名，支持前缀、后缀和自动处理重名。

### 系统要求

- macOS 和 Xcode，需支持 SwiftUI、AVFoundation、CoreImage、CoreMedia 和 Vision。
- 当前 Xcode 工程配置的 macOS deployment target 为 `26.5`，Swift 版本为 `5.0`。
- 可选：安装提供 `mediainfo` 命令的 MediaInfo CLI，用于显示更完整的源文件元数据。

### 构建和运行

1. 用 Xcode 打开 `OCRTimecode.xcodeproj`。
2. 选择 `OCRTimecode` scheme。
3. 点击 Run，或使用 `Command-R` 构建并启动应用。
4. 第一次启动会自动载入内置样片，也可以点击“载入样片”手动切换测试素材。

### 基本使用流程

1. 点击“文件”导入视频，点击“文件夹”导入一个素材文件夹，或把视频/文件夹拖到窗口中。
2. 在右侧“检测区域”调整 ROI。默认预设面向左下角 QTake 画面信息，也可以保存自己的 ROI 预设。
3. 勾选需要识别的字段：文件名、卷号、时间码。
4. 在“源时间码帧率”中选择自动、24、25 或 30 fps。自动模式会在候选帧率中选择最稳定的结果。
5. 对单个素材点击列表中的“提取”，或点击顶部“全部提取”批量 OCR。
6. 检查结果、置信度、漂移提示和当前 TMCD 对比；必要时在元数据编辑区手动修正。
7. 点击“导出 CSV”，生成 Resolve 可导入的元数据文件。

### DaVinci Resolve CSV

导出的 CSV 使用原始媒体文件名进行匹配，不写入 Clip Directory，避免触发错误重连。当前会按可用数据输出以下字段：

- `File Name`
- `Duration TC`
- `Reel Number`
- `Camera #`
- `Start TC`
- `End TC`
- `Start Frame`
- `End Frame`
- `Frames`

在 Resolve 中可通过媒体池的 metadata import 流程导入该 CSV，并用 `File Name` 匹配已有媒体。

### 时间码写入和改名

点击右下角齿轮打开“项目设置”：

- 启用“时间码烧录按钮”后，可以选择“烧录到源文件”或“复制到新文件夹并烧录”。
- “烧录到源文件”会直接修改列表内原始 MOV/QuickTime 文件的 TMCD sample，只支持已有可写 TMCD 轨道的文件；执行前请备份。
- “复制到新文件夹并烧录”会保留源文件不变；没有 TMCD 轨道时会尝试重新封装为带 TMCD 的 MOV。
- 启用“复制改名按钮”后，可以按识别或手动输入的文件名复制到新文件夹，并可添加统一前缀/后缀。
- 同时启用时间码烧录和改名时，会出现“烧录并改名”按钮。

### 支持的视频扩展名

`mov`, `mp4`, `m4v`, `mxf`, `avi`, `mkv`, `mts`, `m2ts`, `mpg`, `mpeg`

实际可读取范围仍取决于 macOS/AVFoundation 对对应编码和容器的支持。

### 当前限制

- OCR 依赖画面文字清晰度和 ROI 位置；不同 QTake 布局通常需要保存单独的 ROI 预设。
- 23.976 当前按 24 帧号制处理。
- 29.97 drop-frame 尚未实现。
- 直接写入源文件仅适用于已有可写 QuickTime TMCD 轨道的 MOV/QuickTime 文件。
- 这是一个本地 macOS 工具，识别和处理流程不需要联网。

## English

### What It Is For

OCRTimecode is designed for video files that already have clip metadata burned into the picture, such as QTake monitor recordings or dailies. It is useful when the file does not contain reliable QuickTime timecode metadata, or when DaVinci Resolve needs batch Reel / Camera / Start TC metadata.

### Features

- Import individual videos, multiple videos, folders, or drag files directly into the app.
- Define visual OCR regions for clip name, reel number, and timecode.
- Save, rename, import, and export ROI presets as JSON.
- Analyze one clip or the whole queue.
- Sample multiple frames and resolve stable metadata from repeated OCR readings.
- Detect source timecode frame rate with Automatic, 24, 25, and 30 fps modes.
- Warn about frame-rate mismatch, suspected drift, high-risk timecode readings, and mismatch against existing TMCD metadata.
- Read existing file metadata; when `mediainfo` is installed, the app displays richer container, codec, frame-rate, duration, and timecode details.
- Manually override clip name, start TC, reel number, and camera ID before export.
- Export DaVinci Resolve metadata CSV.
- Optionally write recovered start timecode into QuickTime TMCD metadata.
- Optionally copy files into a new folder with names based on recognized or manually entered clip names.

### Requirements

- macOS and Xcode with SwiftUI, AVFoundation, CoreImage, CoreMedia, and Vision support.
- The current Xcode project is configured with macOS deployment target `26.5` and Swift `5.0`.
- Optional: install the MediaInfo CLI that provides the `mediainfo` executable for richer source metadata display.

### Build And Run

1. Open `OCRTimecode.xcodeproj` in Xcode.
2. Select the `OCRTimecode` scheme.
3. Press Run, or use `Command-R`.
4. The app loads a bundled sample on first launch. You can also use the sample menu to switch between included test clips.

### Basic Workflow

1. Import video files, import a folder, or drag files/folders into the window.
2. Adjust the ROI boxes in the preview. The default preset targets a lower-left QTake layout.
3. Enable the fields you want to OCR: clip name, reel, and/or timecode.
4. Choose the source timecode frame rate: Automatic, 24, 25, or 30 fps.
5. Analyze a single clip from the queue, or click the top “Analyze All” button.
6. Review confidence, notes, drift diagnostics, and the existing TMCD comparison.
7. Manually correct metadata if needed.
8. Export the DaVinci Resolve metadata CSV.

### DaVinci Resolve CSV

The exported CSV matches media by the original file name and intentionally does not include Clip Directory, which helps avoid accidental relinking. Depending on available metadata, it can write:

- `File Name`
- `Duration TC`
- `Reel Number`
- `Camera #`
- `Start TC`
- `End TC`
- `Start Frame`
- `End Frame`
- `Frames`

Import the CSV through Resolve's media-pool metadata import flow and match existing clips by `File Name`.

### Timecode Writing And Renaming

Open Project Settings from the gear button in the lower-right corner, or press `Command-P`.

- Enable the timecode burn button to write recovered start TC into TMCD metadata.
- Source-file mode directly modifies the original MOV/QuickTime file and requires an existing writable TMCD track. Back up originals first.
- Copy-to-folder mode leaves sources unchanged and attempts to create MOV outputs with TMCD metadata when the source has no writable TMCD track.
- Enable copy-and-rename to copy files into a new folder using recognized or manually entered clip names.
- Prefixes and suffixes can be configured for renamed outputs.
- When both timecode writing and renaming are enabled, the app exposes a combined burn-and-rename action.

### Supported Video Extensions

`mov`, `mp4`, `m4v`, `mxf`, `avi`, `mkv`, `mts`, `m2ts`, `mpg`, `mpeg`

Actual decode support depends on macOS and AVFoundation support for the file's container and codec.

### Current Limitations

- OCR quality depends on readable burned-in text and accurate ROI placement.
- Different QTake layouts normally need separate ROI presets.
- 23.976 is currently treated as 24-frame timecode numbering.
- 29.97 drop-frame support is not implemented yet.
- Direct source-file TMCD writing only supports MOV/QuickTime files with an existing writable TMCD track.
- Processing is local and does not require network access.
