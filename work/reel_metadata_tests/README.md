# QuickTime Reel Metadata Test Set

All MOV files are 1280x720, 24 fps, about 4 seconds, with a QuickTime `tmcd`
timecode track starting at `12:00:00:00`.

| File | Expected Reel | Write Method | Metadata Keys |
| --- | --- | --- | --- |
| `reel_00_base_tc_only.mov` | none | ffmpeg generated base | timecode only |
| `reel_01_ffmpeg_reel_name_A101.mov` | A101 | ffmpeg copy | `reel_name=A101` |
| `reel_02_ffmpeg_qt_reel_B202.mov` | B202 | ffmpeg copy + mdta | `com.apple.quicktime.reel=B202` |
| `reel_03_ffmpeg_generic_reel_C303.mov` | C303 | ffmpeg copy + mdta | `reel=C303` |
| `reel_04_ffmpeg_tape_D404.mov` | D404 | ffmpeg copy + mdta | `tape=D404` |
| `reel_05_ffmpeg_all_reel_keys_E505.mov` | E505 | ffmpeg copy + mdta | `reel_name`, `com.apple.quicktime.reel`, `reel`, `tape` |
| `reel_06_swift_qt_reel_F606.mov` | F606 | AVFoundation passthrough | `com.apple.quicktime.reel=F606` |
| `reel_07_swift_reel_name_G707.mov` | G707 | AVFoundation passthrough | `reel_name=G707` |
| `reel_08_swift_all_reel_keys_H808.mov` | H808 | AVFoundation passthrough | `com.apple.quicktime.reel`, `reel_name`, `reel`, `tape` |

Suggested Resolve check:

1. Import the whole folder into Media Pool.
2. Show columns for Reel Name / Reel Number / Tape Name if available.
3. Confirm which expected value appears for each file.
4. Note whether Resolve prefers one key when multiple keys exist.
