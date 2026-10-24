# OCR Selection and Sample Ordering

## Fixes

- Timecode crops respect the selected ROI. Other fields retain their existing
  capture margin.
- A recognized line such as `A 14:10:10:10` produces `14:10:10:10`. Original
  OCR remains available in the sample text tooltip.
- The strict timecode parser validates the whole string, including field widths,
  separators, numeric ranges, frame limits, and existing DF checks. It no longer
  silently discards malformed components such as `A:14:10:10:10`.
- A candidate with two distinct timecodes is rejected. Character corrections
  remain recorded and continue to trigger review.
- All sampling passes are sorted together by actual rational presentation time,
  then field order. Readings of the same frame and field retain their stable
  order. The log shows video frame indices, independently of the source TC rate.
- Source rate ranking considers whole-clip start-frame support before counting
  survivors of adjacent-frame validation. Exact ties provisionally display the
  video rate and remain marked as ambiguous.

## Automated Checks

Run the built-in regression suite:

```sh
./script/test_ocr_regression.sh
```

It covers malformed SMPTE inputs, crop bounds, labeled and ambiguous candidates,
character correction, fallback preprocessing, rational adjacent-frame sequences
at 23.976/24/25/29.97 NDF/DF/30, confidence gates, exact PTS ordering, retry batches,
duplicates, missing PTS, and rate inference with discontinuous monitor overlays.
The four bundled videos retain their expected clip names, reels, and start TCs.

Run the external field regression:

```sh
./script/test_field_samples.sh /path/to/sample-directory
```

The external set contains 15 MOV clips, five takes across three cameras. The
runner checks both a tight timecode ROI and one including the preceding label:
30 analyses and 630 sampled timecode readings. First-frame ground truth is
transcribed from the actual encoded frames, independently of MOV metadata.
Source footage and generated images are not committed.

The field test checks first-frame recognition against that ground truth, strict
format validity of every normalized reading, chronological ordering, the
provisional 25fps rate, and the confidence gate for rejected temporal sequences.
All 30 analyses pass these checks, covering 630 valid SMPTE readings.
Passing it does **not** mean a
clip's inferred start TC or source rate is safe for automatic export.

## Confirmed Source Limitation

The original monitor recordings repeat and skip burned-in labels. For example,
eight consecutive frames around 8.32 seconds in take 1, camera A show:

```text
13:23:27:23
13:23:27:23
13:23:27:24
13:23:28:00
13:23:28:02
13:23:28:03
13:23:28:03
13:23:28:04
```

These are visible pixels in the source, not OCR substitutions. Strict adjacent
sequence validation therefore continues to reject some readings, and all 30
field analyses remain below the trusted confidence threshold. Some clips have no
validated start TC; others can differ from the first visible label by a frame.
This change does not bypass those checks or guarantee a constant start-TC offset
for these recordings.

The MOV metadata also differs from the burned-in first frame. In take 1, camera
A, ffprobe reports `13:23:19:16` while the first visible label is `13:23:19:15`.
Existing container timecode is therefore not used as OCR ground truth.

## Local Build

```sh
./script/build_and_run.sh --verify
```

This builds and opens `build/OCRFixDerivedData/Build/Products/Debug/Aquarius.app`.
The Codex Run action uses the same script. It preserves the existing desktop
bundle and does not publish or replace a release.

Regression scripts retain temporary output and caches for diagnosis; they do not
delete test artifacts. No test writes to or renames the original media.
