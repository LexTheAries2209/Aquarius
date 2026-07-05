# OCRTimecode

OCRTimecode is a local macOS utility for recovering clip metadata from burned-in picture overlays. It was built around QTake / dailies workflows where a proxy or monitor recording shows the clip name, reel, and source timecode on screen, but the file itself does not carry reliable editorial metadata.

OCRTimecode 是一个本地 macOS 工具，用于从视频画面里已经烧录的文字信息中恢复素材元数据。它主要面向 QTake、现场监看录制、dailies 或代理文件场景：画面上能看到文件名、卷号和源时间码，但文件自身缺少可靠的剪辑元数据。

---

## 中文说明

### 项目定位

OCRTimecode 不是剪辑软件，也不是完整的媒体资产管理系统。它的目标很窄：把画面里可见的 `文件名 / 卷号 / 时间码` 识别出来，整理成后期软件更容易读取的元数据。

典型用途：

- QTake 录制文件只有画面烧录信息，缺少可用的 QuickTime timecode track。
- DaVinci Resolve 里需要批量补充 Reel、Camera、Start TC。
- 需要先 OCR、人工复核，再导出 CSV 或生成改名后的交付文件。
- 需要把识别出的起始时间码写入 MOV / QuickTime 的 TMCD 轨道。

### 核心功能

- 导入单个视频、多个视频、文件夹，或直接拖拽素材到窗口。
- 在视频预览上调整 OCR 检测区域，支持文件名、卷号、时间码三个字段。
- 保存、重命名、导入和导出 ROI JSON 预设，适配不同 QTake 画面布局。
- 对单个素材提取，或对当前列表批量提取。
- 多点抽样识别并做一致性判断，输出可信、需复核或失败状态。
- 支持源时间码帧率自动判断，也可以手动指定 24、25、30 fps。
- 检测视频帧率与源 TC 帧率不一致、疑似漂移、高风险时间码等情况。
- 读取现有文件元数据；如果系统安装了 `mediainfo`，会显示更完整的容器、编码、帧率、时长和当前 timecode 信息。
- 支持手动覆盖当前素材的文件名和起始 TC，也支持对当前列表批量覆盖卷号和机位号。
- 导出 DaVinci Resolve 可导入的元数据 CSV。
- 可选将起始时间码写入 QuickTime TMCD 轨道。
- 可选复制到新文件夹并按识别或手动输入的文件名改名。
- 可选在复制改名后自动生成一份配套 DaVinci CSV，使用改名后的真实文件名作为 Resolve 匹配键。

### 系统要求

- macOS。
- Xcode，当前工程使用 SwiftUI / AVFoundation / CoreImage / CoreMedia / Vision。
- 当前工程配置：
  - Swift `5.0`
  - macOS deployment target `13.0`
- 可选依赖：MediaInfo CLI。安装后需能在命令行中找到 `mediainfo`。

### 构建和运行

1. 用 Xcode 打开 `OCRTimecode.xcodeproj`。
2. 选择 `OCRTimecode` scheme。
3. 点击 Run，或按 `Command-R`。
4. 第一次启动会自动载入内置样片，也可以通过顶部“载入样片”菜单切换测试素材。

### 基本使用流程

1. 点击“文件”导入视频，点击“文件夹”导入素材目录，或把文件/文件夹拖进窗口。
2. 在预览画面上调整 ROI 框。默认预设面向左下角 QTake 信息布局。
3. 勾选需要识别的字段：文件名、卷号、时间码。
4. 选择源时间码帧率：自动、24、25 或 30 fps。
5. 点击单个素材行里的“提取”，或点击顶部“全部提取”批量 OCR。
6. 检查识别结果、置信度、漂移诊断和当前 TMCD 对比。
7. 必要时在元数据编辑区手动修正文件名、卷号、机位号或起始 TC。
8. 根据工作流选择：
   - 导出 DaVinci CSV。
   - 复制并改名。
   - 写入 TMCD。
   - 烧录时间码并改名到新文件夹。

### DaVinci Resolve CSV

导出的 CSV 用文件名匹配已有媒体，不写入 Clip Directory，目的是避免 Resolve 错误重连素材。

当前可输出字段包括：

- `File Name`
- `Duration TC`
- `Reel Number`
- `Camera #`
- `Start TC`
- `End TC`
- `Start Frame`
- `End Frame`
- `Frames`

如果启用了“复制改名后自动生成配套 DaVinci CSV”，生成的配套 CSV 会使用输出文件夹里改名后的真实文件名作为 `File Name`，更适合直接导入 Resolve 匹配新文件。

### 时间码写入和改名

右下角齿轮按钮会打开“项目设置”：

- 启用“时间码烧录按钮”后，可选择“烧录到源文件”或“复制到新文件夹并烧录”。
- “烧录到源文件”会直接修改列表内原始 MOV / QuickTime 文件的 TMCD sample。请先备份原始文件。
- 直接写源文件只支持已有可写 TMCD 轨道的文件。
- “复制到新文件夹并烧录”会保留源文件不变；如果源文件没有 TMCD 轨道，会尝试重新封装为带 TMCD 的 MOV。
- 启用“复制改名按钮”后，可按识别或手动输入的文件名复制到新文件夹。
- 改名支持统一前缀、后缀；同名文件会自动追加序号。
- 同时启用时间码烧录和复制改名后，会出现“烧录并改名”按钮。

### 支持的视频格式

当前仅声明支持 MOV / QuickTime 文件。

代码层面仍可能通过 AVFoundation 打开其他容器，但这些格式尚未经过系统测试，不作为当前项目的正式支持范围。时间码写入功能也主要围绕 MOV / QuickTime 的 TMCD 轨道设计。

### 当前限制

- OCR 依赖画面文字清晰度和 ROI 位置；不同叠字布局通常需要单独的 ROI 预设。
- 23.976 当前按 24 帧号制处理。
- 29.97 drop-frame 尚未实现。
- 直接写入源文件仅适用于已有可写 QuickTime TMCD 轨道的 MOV / QuickTime 文件。
- 工具在本机运行，不需要联网。

---

## English

### Purpose

OCRTimecode is not an editor or a full media asset manager. It focuses on one job: recover visible `clip name / reel / timecode` information from the picture and turn it into usable editorial metadata.

Common use cases:

- QTake or monitor-recorded files show burned-in metadata but do not carry usable QuickTime timecode.
- DaVinci Resolve needs batch Reel, Camera, and Start TC metadata.
- A user wants OCR first, manual review second, then CSV export or renamed outputs.
- A MOV / QuickTime file needs the recovered start timecode written into its TMCD track.

### Features

- Import individual videos, multiple videos, folders, or drag files directly into the window.
- Define OCR regions visually on top of the video preview.
- Recognize clip name, reel number, and timecode fields.
- Save, rename, import, and export ROI presets as JSON.
- Analyze one clip or the whole queue.
- Sample multiple frames and resolve stable metadata from repeated OCR readings.
- Detect source timecode rate automatically, or use 24, 25, or 30 fps manually.
- Warn about frame-rate mismatch, suspected drift, high-risk readings, and mismatch against existing TMCD metadata.
- Read existing source metadata; with the optional `mediainfo` command installed, the app displays richer container, codec, frame-rate, duration, and timecode details.
- Manually override clip name, start TC, reel number, and camera ID before export.
- Export DaVinci Resolve metadata CSV.
- Optionally write recovered start TC into QuickTime TMCD metadata.
- Optionally copy files into a new folder using recognized or manually entered clip names.
- Optionally create a companion DaVinci CSV after renaming, using the renamed output files as the Resolve match keys.

### Requirements

- macOS.
- Xcode with SwiftUI, AVFoundation, CoreImage, CoreMedia, and Vision support.
- Current project settings:
  - Swift `5.0`
  - macOS deployment target `13.0`
- Optional: MediaInfo CLI available as `mediainfo`.

### Build And Run

1. Open `OCRTimecode.xcodeproj` in Xcode.
2. Select the `OCRTimecode` scheme.
3. Press Run, or use `Command-R`.
4. A bundled sample loads on first launch. The sample menu can switch between included test clips.

### Basic Workflow

1. Import video files, import a folder, or drag files/folders into the window.
2. Adjust the ROI boxes in the video preview. The default preset targets a lower-left QTake layout.
3. Enable the fields to OCR: clip name, reel, and/or timecode.
4. Choose the source timecode frame rate: Automatic, 24, 25, or 30 fps.
5. Analyze a single clip from the queue, or click “Analyze All”.
6. Review confidence, notes, drift diagnostics, and the existing TMCD comparison.
7. Correct metadata manually if needed.
8. Export Resolve CSV, copy and rename files, write TMCD, or burn-and-rename into a new folder.

### DaVinci Resolve CSV

The CSV matches existing media by file name and intentionally omits Clip Directory to reduce the chance of accidental relinking.

Available fields:

- `File Name`
- `Duration TC`
- `Reel Number`
- `Camera #`
- `Start TC`
- `End TC`
- `Start Frame`
- `End Frame`
- `Frames`

When companion CSV generation is enabled for renamed outputs, the CSV uses the actual renamed output files as `File Name` values, which is better for importing those new files into Resolve.

### Timecode Writing And Renaming

Open Project Settings from the gear button in the lower-right corner, or press `Command-P`.

- Enable the timecode burn button to write recovered start TC into TMCD metadata.
- Source-file mode directly modifies the original MOV / QuickTime file. Back up originals first.
- Source-file mode requires an existing writable TMCD track.
- Copy-to-folder mode leaves source files unchanged and attempts to create MOV outputs with TMCD metadata when needed.
- Enable copy-and-rename to copy files into a new folder using recognized or manually entered clip names.
- Prefixes and suffixes can be configured for renamed outputs.
- When both timecode writing and renaming are enabled, the app exposes a combined burn-and-rename action.

### Supported Video Format

Only MOV / QuickTime files are officially supported at this point.

The code may still open other containers through AVFoundation, but those formats have not been systematically tested and are outside the current supported scope. Timecode writing is also designed primarily around MOV / QuickTime TMCD tracks.

### Current Limitations

- OCR quality depends on readable burned-in text and accurate ROI placement.
- Different QTake layouts normally need separate ROI presets.
- 23.976 is currently treated as 24-frame timecode numbering.
- 29.97 drop-frame support is not implemented yet.
- Direct source-file TMCD writing only supports MOV / QuickTime files with an existing writable TMCD track.
- Processing is local and does not require network access.

---

## Development Notes

- `OCRTimecode/` contains the app source.
- `OCRTimecode/Samples/` contains bundled sample videos used by the app.
- `work/` contains local smoke-test utilities, media experiments, and Resolve metadata tests.
- Generated module caches, compiled smoke-test binaries, Xcode user data, local traces, and build outputs are ignored by `.gitignore`.

## License / 授权

OCRTimecode is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`). See [LICENSE](LICENSE).

OCRTimecode 使用 GNU General Public License v3.0 only (`GPL-3.0-only`) 授权。使用、修改和分发本项目时，请遵守 [LICENSE](LICENSE) 中的条款。
