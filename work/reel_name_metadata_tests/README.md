# QuickTime Reel Name Metadata Test Set

All MOV files are 1280x720, 24 fps, about 4 seconds, with a QuickTime `tmcd`
timecode track starting at `12:00:00:00`.

Import this folder into DaVinci Resolve and show the `Reel Name` column first.
If needed, also show `Reel Number`, `Roll/Card`, and `Tape Name` for comparison.

| File | Expected Reel Name | Write Method | Metadata Keys |
| --- | --- | --- | --- |
| `reel_name_00_base_tc_only.mov` | none | ffmpeg generated base | timecode only |
| `reel_name_01_ffmpeg_reel_name_RN101.mov` | RN101 | ffmpeg copy | `reel_name=RN101` |
| `reel_name_02_ffmpeg_literal_reel_name_RN202.mov` | RN202 | ffmpeg copy | `Reel Name=RN202` |
| `reel_name_03_ffmpeg_mdta_literal_reel_name_RN303.mov` | RN303 | ffmpeg copy + mdta | `Reel Name=RN303` |
| `reel_name_04_ffmpeg_mdta_all_reel_keys_RN404.mov` | RN404 | ffmpeg copy + mdta | `com.apple.quicktime.reel`, `reel_name`, `reel`, `tape` |
| `reel_name_05_swift_literal_reel_name_RN505.mov` | RN505 | AVFoundation passthrough | `Reel Name=RN505` |
| `reel_name_06_swift_qt_reelname_RN606.mov` | RN606 | AVFoundation passthrough | `com.apple.quicktime.reelname=RN606` |
| `reel_name_07_swift_all_reel_name_keys_RN707.mov` | RN707 | AVFoundation passthrough | `Reel Name`, `com.apple.quicktime.reel`, `com.apple.quicktime.reelname`, `reel_name`, `reel`, `tape` |

Local metadata checks:

- `reel_name_04_ffmpeg_mdta_all_reel_keys_RN404.mov` shows custom reel keys in ffprobe and MediaInfo.
- `reel_name_07_swift_all_reel_name_keys_RN707.mov` shows `Reel Name : RN707` in MediaInfo and preserves the `tmcd` track.

Suggested Resolve check:

1. Import the whole folder into the Media Pool.
2. Switch Media Pool to list view.
3. Show the `Reel Name` column.
4. Compare which row displays `RN101` through `RN707`.
5. If only `RN505` or `RN707` works, Swift QuickTime metadata key `Reel Name` is probably the best embedded metadata route.
6. If none works, use CSV `Reel Name` import or folder/filename reel extraction instead of embedded MOV reel metadata.
