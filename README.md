# Aquarius

Formerly OCRTimecode.

Aquarius is a local macOS utility for recovering clip metadata from burned-in picture overlays. It was built around QTake / dailies workflows where a proxy or monitor recording shows the clip name, reel, and source timecode on screen, but the file itself does not carry reliable editorial metadata.

Aquarius 是一个本地 macOS 工具，用于从视频画面里已经烧录的文字信息中恢复素材元数据。它主要面向 QTake、现场监看录制、dailies 或代理文件场景：画面上能看到文件名、卷号和源时间码，但文件自身缺少可靠的剪辑元数据。

[Latest Release / 最新版本](https://github.com/LexTheAries2209/Aquarius/releases/latest): `v1.0.2`

Bilingual release notes / 双语发布说明：[docs/releases/v1.0.2.md](docs/releases/v1.0.2.md)

---

## 中文说明

### 项目定位

Aquarius 不是剪辑软件，也不是完整的媒体资产管理系统。它的目标很窄：把画面里可见的 `文件名 / 卷号 / 时间码` 识别出来，整理成后期软件更容易读取的元数据。

### 下载和安装

1. 前往 [GitHub Releases](https://github.com/LexTheAries2209/Aquarius/releases/latest) 下载 `Aquarius-v1.0.2-macOS.zip`。
2. 解压后把 `Aquarius V1.0.2.app` 放到 `Applications` 或你的本地工具目录。
3. 首次打开时，如果 macOS Gatekeeper 提示来自互联网下载的 App，请在 Finder 中右键点击 App 后选择“打开”，或在“系统设置 > 隐私与安全性”中允许打开。

V1.0.2 的中文发布说明见 [docs/releases/v1.0.2.zh-CN.md](docs/releases/v1.0.2.zh-CN.md)。

典型用途：

- QTake 录制文件只有画面烧录信息，缺少可用的 QuickTime timecode track。
- DaVinci Resolve 里需要批量补充 Reel、Camera、Start TC。
- 需要先 OCR、人工复核，再导出元数据或生成改名后的交付文件。
- 需要把识别出的起始时间码写入 MOV / QuickTime 的 TMCD 轨道。

### 核心功能

- 导入单个视频、多个视频、文件夹，或直接拖拽素材到窗口。
- 在视频预览上调整 OCR 检测区域，支持文件名、卷号、时间码三个字段。
- 保存、重命名、导入和导出 ROI JSON 预设，适配不同 QTake 画面布局。
- 对单个素材提取，或对当前列表批量提取。
- 多点抽样识别并做一致性判断，输出可信、需复核或失败状态。
- 支持源时间码帧率自动判断，也可以手动指定 23.976、24、25、29.97 NDF、29.97 DF、30。
- 检测视频帧率与源 TC 帧率不一致、疑似漂移、高风险时间码等情况；详细诊断可在项目设置里按需显示。
- 读取现有文件元数据；如果系统安装了可选的 MediaInfo CLI（`mediainfo`），会显示更完整的容器、编码、帧率、时长和当前 timecode 信息。
- 支持手动覆盖当前素材的文件名和起始 TC，也支持对当前列表批量覆盖卷号和机位号。
- 导出面向 DaVinci Resolve 或 Adobe Premiere Pro 的元数据。
- 可选将起始时间码写入 QuickTime TMCD 轨道。
- 可选复制到新文件夹并按识别或手动输入的文件名改名。
- 可选在复制改名后自动生成一份配套元数据 CSV，使用改名后的真实文件名作为目标软件匹配键。

### 系统要求

- 使用发布版：macOS `13.0` 或更新版本，不需要 Xcode。
- 从源码构建：需要 Xcode，当前工程使用 SwiftUI / AVFoundation / CoreImage / CoreMedia / Vision。
- 当前源码工程配置：
  - Swift `5.0`
  - macOS deployment target `13.0`
- 可选依赖：MediaInfo CLI（命令名为 `mediainfo`）。Aquarius 当前不内置 MediaInfo CLI；没有安装时，OCR、CSV 导出、复制改名和 TMCD 写入仍可使用，但“当前文件”元数据面板只会显示基础提示。
- MediaInfo CLI 安装方式：
  - Homebrew：`brew install media-info`
  - 官方下载：访问 <https://mediaarea.net/en/MediaInfo/Download/Mac_OS>，选择 macOS 的 CLI / Command Line 版本。
- 安装后请确认终端可以运行 `mediainfo --Version`。如果 Aquarius 已经打开，安装后请重新启动 Aquarius 或重新导入素材以重新读取元数据。

### 构建和运行

1. 用 Xcode 打开 `Aquarius.xcodeproj`。
2. 选择 `Aquarius` scheme。
3. 点击 Run，或按 `Command-R`。
4. 第一次启动会自动载入内置样片，也可以通过顶部“载入样片”菜单切换测试素材。

### 基本使用流程

1. 点击“文件”导入视频，点击“文件夹”导入素材目录，或把文件/文件夹拖进窗口。
2. 在预览画面上调整 ROI 框。默认预设面向左下角 QTake 信息布局。
3. 勾选需要识别的字段：文件名、卷号、时间码。
4. 选择源时间码帧率：自动、23.976、24、25、29.97 NDF、29.97 DF 或 30。
5. 点击单个素材行里的“提取”，或点击顶部“全部提取”批量 OCR。
6. 检查识别结果、置信度、漂移诊断和当前 TMCD 对比。
7. 必要时在元数据编辑区手动修正文件名、卷号、机位号或起始 TC。
8. 根据工作流选择：
   - 导出元数据。
   - 复制并改名。
   - 写入 TMCD。
   - 烧录时间码并改名到新文件夹。

### DaVinci Resolve CSV

导出的 CSV 用文件名匹配已有媒体，不写入 Clip Directory，目的是避免 Resolve 错误重连素材。

时间码字段按当前素材的源 TC 帧率计算，而不是简单套用视频文件帧率。自动模式只在 24、25、30 之间推断；23.976、29.97 NDF 和 29.97 DF 需要手动指定。29.97 DF 使用分号时间码格式，例如 `01:00:00;00`，并会拒绝 drop-frame 中不存在的帧标签。

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

如果启用了“复制改名后自动生成配套元数据 CSV”，生成的配套 CSV 会使用输出文件夹里改名后的真实文件名作为 `File Name`，更适合直接导入 Resolve 匹配新文件。

### Adobe Premiere Pro XML

Premiere Pro 导出会生成 `xmeml version="4"` XML 文件，结构参考 SilverStack Lab 的 Adobe Premiere Pro XML：顶层 bin、`Video Clips` 子 bin、每个素材一条 master clip，并写入源文件 `pathurl`、起始 timecode frame、NDF/DF 标记和 reel/cameraroll。

### 时间码写入和改名

右下角齿轮按钮会打开“项目设置”：

- 启用“显示时间码检测详情”后，右侧检查器会显示视频帧率、识别 TC 帧率、TMCD 对比、一致性和漂移信息；关闭时只保留更简洁的源时间码帧率控制和必要风险提示。
- 启用“时间码烧录按钮”后，可选择“烧录到源文件”或“复制到新文件夹并烧录”。
- “烧录到源文件”会直接修改列表内原始 MOV / QuickTime 文件的 TMCD sample。请先备份原始文件。
- 直接写源文件只支持已有可写 TMCD 轨道的文件。
- “复制到新文件夹并烧录”会保留源文件不变；如果源文件没有 TMCD 轨道，会尝试重新封装为带 TMCD 的 MOV。
- 23.976、29.97 NDF 和 29.97 DF 目前可用于 OCR 解析、当前播放 TC 和元数据导出；QuickTime TMCD 写回暂时保护，不会直接写入非整数或 drop-frame TMCD，避免在 flags 未验证前生成错误源时间码。
- 启用“复制改名按钮”后，可按识别或手动输入的文件名复制到新文件夹。
- 改名支持统一前缀、后缀；同名文件会自动追加序号。
- 同时启用时间码烧录和复制改名后，会出现“烧录并改名”按钮。

### 支持的视频格式

当前仅声明支持 MOV / QuickTime 文件。

代码层面仍可能通过 AVFoundation 打开其他容器，但这些格式尚未经过系统测试，不作为当前项目的正式支持范围。时间码写入功能也主要围绕 MOV / QuickTime 的 TMCD 轨道设计。

### 当前限制

- OCR 依赖画面文字清晰度和 ROI 位置；不同叠字布局通常需要单独的 ROI 预设。
- 自动源 TC 帧率推断只测试 24、25、30；23.976 和 29.97 需要手动选择。
- 23.976 使用 24 帧号制标签，并按 24000/1001 计数生成当前 TC 和 CSV。
- 29.97 NDF 使用 30 帧号制标签，并按 30000/1001 计数生成当前 TC 和 CSV。
- 29.97 DF 支持手动解析和 CSV 导出，要求使用分号格式；QuickTime TMCD 写回尚未启用。
- 直接写入源文件仅适用于已有可写 QuickTime TMCD 轨道的 MOV / QuickTime 文件。
- 工具在本机运行，不需要联网。

---

## English

### Purpose

Aquarius is not an editor or a full media asset manager. It focuses on one job: recover visible `clip name / reel / timecode` information from the picture and turn it into usable editorial metadata.

### Download And Install

1. Download `Aquarius-v1.0.2-macOS.zip` from [GitHub Releases](https://github.com/LexTheAries2209/Aquarius/releases/latest).
2. Unzip it and move `Aquarius V1.0.2.app` to `Applications` or your local tools folder.
3. On first launch, if macOS Gatekeeper shows an internet-download warning, right-click the app in Finder and choose Open, or allow it from System Settings > Privacy & Security.

English release notes for V1.0.2 are available at [docs/releases/v1.0.2.en.md](docs/releases/v1.0.2.en.md).

Common use cases:

- QTake or monitor-recorded files show burned-in metadata but do not carry usable QuickTime timecode.
- DaVinci Resolve needs batch Reel, Camera, and Start TC metadata.
- A user wants OCR first, manual review second, then metadata export or renamed outputs.
- A MOV / QuickTime file needs the recovered start timecode written into its TMCD track.

### Features

- Import individual videos, multiple videos, folders, or drag files directly into the window.
- Define OCR regions visually on top of the video preview.
- Recognize clip name, reel number, and timecode fields.
- Save, rename, import, and export ROI presets as JSON.
- Analyze one clip or the whole queue.
- Sample multiple frames and resolve stable metadata from repeated OCR readings.
- Detect source timecode rate automatically, or manually choose 23.976, 24, 25, 29.97 NDF, 29.97 DF, or 30.
- Warn about frame-rate mismatch, suspected drift, high-risk readings, and mismatch against existing TMCD metadata; detailed diagnostics can be hidden or shown from Project Settings.
- Read existing source metadata; with the optional MediaInfo CLI (`mediainfo`) installed, the app displays richer container, codec, frame-rate, duration, and timecode details.
- Manually override clip name, start TC, reel number, and camera ID before export.
- Export metadata for DaVinci Resolve or Adobe Premiere Pro.
- Optionally write recovered start TC into QuickTime TMCD metadata.
- Optionally copy files into a new folder using recognized or manually entered clip names.
- Optionally create a companion metadata CSV after renaming, using the renamed output files as the target app match keys.

### Requirements

- Release build: macOS `13.0` or later; Xcode is not required.
- Source build: Xcode with SwiftUI, AVFoundation, CoreImage, CoreMedia, and Vision support.
- Current source project settings:
  - Swift `5.0`
  - macOS deployment target `13.0`
- Optional dependency: MediaInfo CLI, available as the `mediainfo` command. Aquarius does not currently bundle MediaInfo CLI; without it, OCR, CSV export, copy/rename, and TMCD writing still work, but the Current File metadata panel will only show a basic prompt.
- Install MediaInfo CLI:
  - Homebrew: `brew install media-info`
  - Official download: visit <https://mediaarea.net/en/MediaInfo/Download/Mac_OS> and choose the macOS CLI / Command Line build.
- After installation, verify that `mediainfo --Version` works in Terminal. If Aquarius is already open, restart Aquarius or re-import the clips so source metadata can be read again.

### Build And Run

1. Open `Aquarius.xcodeproj` in Xcode.
2. Select the `Aquarius` scheme.
3. Press Run, or use `Command-R`.
4. A bundled sample loads on first launch. The sample menu can switch between included test clips.

### Basic Workflow

1. Import video files, import a folder, or drag files/folders into the window.
2. Adjust the ROI boxes in the video preview. The default preset targets a lower-left QTake layout.
3. Enable the fields to OCR: clip name, reel, and/or timecode.
4. Choose the source timecode frame rate: Automatic, 23.976, 24, 25, 29.97 NDF, 29.97 DF, or 30.
5. Analyze a single clip from the queue, or click “Analyze All”.
6. Review confidence, notes, drift diagnostics, and the existing TMCD comparison.
7. Correct metadata manually if needed.
8. Export metadata, copy and rename files, write TMCD, or burn-and-rename into a new folder.

### DaVinci Resolve CSV

The CSV matches existing media by file name and intentionally omits Clip Directory to reduce the chance of accidental relinking.

Timecode fields are calculated from the selected or inferred source TC rate, not blindly from the video file frame rate. Automatic mode only infers 24, 25, or 30; 23.976, 29.97 NDF, and 29.97 DF must be selected manually. 29.97 DF uses semicolon timecode such as `01:00:00;00` and rejects labels that do not exist in drop-frame counting.

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

### Adobe Premiere Pro XML

Premiere Pro export generates an `xmeml version="4"` XML file following the structure used by SilverStack Lab's Adobe Premiere Pro XML: a top-level bin, a `Video Clips` sub-bin, one master clip per source file, and source `pathurl`, timecode frame, NDF/DF display format, and reel/cameraroll metadata.

### Timecode Writing And Renaming

Open Project Settings from the gear button in the lower-right corner, or press `Command-P`.

- Enable detailed timecode diagnostics to show video frame rate, recognized TC rate, TMCD comparison, consistency, and drift details in the inspector; when disabled, the UI keeps only the source TC rate control and necessary risk warnings.
- Enable the timecode burn button to write recovered start TC into TMCD metadata.
- Source-file mode directly modifies the original MOV / QuickTime file. Back up originals first.
- Source-file mode requires an existing writable TMCD track.
- Copy-to-folder mode leaves source files unchanged and attempts to create MOV outputs with TMCD metadata when needed.
- 23.976, 29.97 NDF, and 29.97 DF are currently supported for OCR parsing, current playback TC, and metadata export. QuickTime TMCD writeback is intentionally blocked for non-integer and drop-frame rates until the required flags are validated.
- Enable copy-and-rename to copy files into a new folder using recognized or manually entered clip names.
- Prefixes and suffixes can be configured for renamed outputs.
- When both timecode writing and renaming are enabled, the app exposes a combined burn-and-rename action.

### Supported Video Format

Only MOV / QuickTime files are officially supported at this point.

The code may still open other containers through AVFoundation, but those formats have not been systematically tested and are outside the current supported scope. Timecode writing is also designed primarily around MOV / QuickTime TMCD tracks.

### Current Limitations

- OCR quality depends on readable burned-in text and accurate ROI placement.
- Different QTake layouts normally need separate ROI presets.
- Automatic source TC inference only tests 24, 25, and 30; 23.976 and 29.97 must be selected manually.
- 23.976 uses 24-frame labels and 24000/1001 counting for current TC and CSV output.
- 29.97 NDF uses 30-frame labels and 30000/1001 counting for current TC and CSV output.
- 29.97 DF is supported for manual parsing and CSV export with semicolon format; QuickTime TMCD writeback is not enabled yet.
- Direct source-file TMCD writing only supports MOV / QuickTime files with an existing writable TMCD track.
- Processing is local and does not require network access.

---

## Development Notes

- `Aquarius/` contains the app source.
- `Aquarius/Samples/` contains bundled sample videos used by the app.
- `work/` contains local smoke-test utilities, media experiments, and Resolve metadata tests.
- Generated module caches, compiled smoke-test binaries, Xcode user data, local traces, and build outputs are ignored by `.gitignore`.

## License / 授权

Aquarius source code is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`). See [LICENSE](LICENSE).

Aquarius 源代码使用 GNU General Public License v3.0 only (`GPL-3.0-only`) 授权。使用、修改和分发本项目源代码时，请遵守 [LICENSE](LICENSE) 中的条款。

App icons, branding assets, and bundled sample videos are not covered by the GPLv3 source-code license unless explicitly stated otherwise.

软件图标、品牌视觉资源以及内置样片视频不属于 GPLv3 源代码授权范围，除非另有明确说明。

## Version Naming / 版本命名

The public Display Name uses a three-part version label composed from Xcode Version and Build. For example, `Version = 1.0` and `Build = 2` produces `Aquarius V1.0.2`.

公开显示名使用由 Xcode Version 和 Build 组成的三段式版本名。例如，`Version = 1.0`、`Build = 2` 时，Display Name 显示为 `Aquarius V1.0.2`。
