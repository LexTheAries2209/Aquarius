# Aquarius OCR Benchmark Sample Contract

This document defines the media and ground truth required to measure OCR accuracy, tune review thresholds, and decide whether a local Core ML OCR model should replace or complement Apple Vision.

本文规定用于衡量 OCR 准确率、调整“需复核”阈值，以及判断本地 Core ML OCR 模型是否应替代或补充 Apple Vision 的素材与真值要求。

## 中文

### 素材数量

- 最低可用：`5-10` 个原始短视频，用于定位明显错误和建立第一版回归集。
- 推荐基准：`30-50` 个原始短视频，用于覆盖不同设备、叠字模板、画质和帧率。
- 每个视频应保留连续画面，不能只提供单张截图；时间码至少需要连续三帧才能验证递增关系。
- 截图可以作为字符识别补充样本，但不能单独用于证明起始时间码正确。

### 每个样本必须提供

- 原始视频文件，不要二次转码、缩放、锐化或重新录屏。
- 正确文件名和卷号；画面不包含某字段时明确标记为 `null`。
- 正确参考帧 TC 或起始 TC。
- 视频帧率、源 TC 帧率，以及 DF / NDF。
- 文件名、卷号、时间码各自的 ROI 或可导入 Aquarius 的 ROI JSON 预设。
- 叠字位置和模板来源，例如 QTake、摄影机输出、监看录制或未知。
- Aquarius 当前版本、每个字段的原始 OCR、解析结果、最终结果、置信度和状态。
- 真值确认方式，例如摄影机报告、场记单、原始摄影机文件、QTake 日志或逐帧人工核对。

### 推荐覆盖范围

- 文件名格式：`A006C001` 一类紧凑相机名、QTake 下划线格式、ARRI 格式及项目自定义格式。
- 易混字符：`0/O`、`1/I/L/T`、`2/Z`、`5/S`、`6/G`、`8/B`。
- 时间码：23.976、24、25、29.97 NDF、29.97 DF、30 fps，并覆盖秒、分钟和日界切换附近。
- 画面条件：亮字暗底、暗字亮底、低码率、缩放模糊、压缩振铃、低对比度和部分遮挡。
- ROI：左下、右下、顶部等不同位置，以及紧框和包含标签文字的宽框。
- 结果分布：正确、可纠正、必须复核和不可识别的样本都要保留，不要只提交清晰成功案例。

### 建议交付结构

```text
Aquarius-OCR-Benchmark/
  manifest.json
  roi-presets/
  videos/
  screenshots/
```

`manifest.json` 每条记录建议包含：

```json
{
  "sample_id": "project-camera-date-001",
  "video_file": "videos/sample-001.mov",
  "overlay_source": "QTake",
  "expected": {
    "clip_name": "A006C001",
    "roll": null,
    "start_timecode": "10:04:02:06"
  },
  "rate": {
    "video_fps": 23.976,
    "timecode_fps": 23.976,
    "drop_frame": false
  },
  "roi_preset": "roi-presets/project-layout.json",
  "aquarius_baseline": {
    "version": "commit-or-build-id",
    "raw_ocr": "A00GC00T",
    "parsed_value": "A006C001",
    "final_status": "需复核"
  },
  "truth_source": "camera report and frame-by-frame check"
}
```

文件名、卷号和时间码使用独立基线记录时，`raw_ocr`、`parsed_value`、`final_status` 应分别保存，不要只记录最终字符串。涉及演员、项目名或未公开画面的素材，请在提供前完成授权或使用安全的脱敏副本；脱敏不能改变叠字区域的像素。

### 提供素材后的收益

- 将错误拆分为取帧、ROI、预处理、Vision OCR、字段解析和多帧聚合六个阶段。
- 量化文件名完全匹配率、字符错误率、起始 TC 准确率、错误进入“可信”的数量和单条分析耗时。
- 针对真实错误调整候选评分和置信阈值，重点消除高置信错误。
- 固化发布回归集，后续每次修改都可以比较同一批素材，而不是依赖目测。
- 公平比较增强 Vision 与本地模型，避免仅凭少量漂亮案例引入模型和包体成本。

### 本地模型准入标准

本地模型应作为单独功能实施。只有同一盲测集同时满足以下条件，才进入正式应用：

- 相对错误数至少降低 `30%`。
- 不增加错误结果进入“可信”的数量。
- 总分析时间不超过增强 Vision 的 `2` 倍。
- 应用包体增加不超过 `100 MB`。
- 可以稳定使用 M 系列芯片上的 Core ML / Neural Engine。

## English

### Dataset size

- Minimum: `5-10` original short videos for fault isolation and an initial regression set.
- Recommended: `30-50` original short videos covering devices, overlay layouts, image quality, and frame rates.
- Keep consecutive video frames. Timecode continuity cannot be validated from a screenshot alone and requires at least three adjacent frames.

### Required per sample

- Original, untranscoded video.
- Ground-truth clip name, reel, reference or start TC, video rate, source TC rate, and DF/NDF mode.
- Field ROIs or an importable Aquarius ROI JSON preset.
- Overlay source and location.
- Aquarius version plus raw OCR, parsed value, final value, confidence, and review status for each field.
- A verifiable truth source such as a camera report, script log, original camera file, QTake log, or frame-by-frame review.

The set should cover compact camera names, QTake and ARRI formats, common character confusions, all supported timecode rates, multiple overlay positions, and both clean and degraded images. Preserve failures and review cases instead of selecting only successful samples.

### What the dataset enables

- Attribute errors to extraction, ROI, preprocessing, OCR, parsing, or temporal aggregation.
- Measure exact clip-name accuracy, character error rate, start-TC accuracy, false-trusted results, and runtime.
- Calibrate confidence against real failures and build a stable release regression suite.
- Compare enhanced Vision and local Core ML OCR under the same blind-test gates listed above.
