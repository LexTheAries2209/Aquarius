# EDL Reel Comment Tests

This folder tests DaVinci Resolve's "Extract reel names from EDL comments"
behavior.

## Media

All files in `media/` are 1280x720 MOV files, 24 fps, about 4 seconds long,
with a QuickTime `tmcd` source timecode track starting at `12:00:00:00`.

## EDL Files

| EDL | Expected Reel | Test Pattern |
| --- | --- | --- |
| `edl_00_reel_column_control.edl` | A101 / B202 | Reel written directly in CMX event reel column |
| `edl_01_comment_reel_colon.edl` | A101 | `* REEL: A101` |
| `edl_02_comment_reel_name.edl` | B202 | `* REEL NAME: B202` |
| `edl_03_comment_tape.edl` | C303 | `* TAPE: C303` |
| `edl_04_from_clip_name_only.edl` | D404 | `* FROM CLIP NAME: D404_C001_0001.mov` |
| `edl_05_source_file_basename.edl` | E505 | `* SOURCE FILE: E505_C001_0001.mov` |
| `edl_06_source_file_absolute_path.edl` | F606 | Absolute `* SOURCE FILE:` path |
| `edl_07_multi_pattern_all_events.edl` | A101-F606 | Combined multi-event test |
| `edl_08_comment_reel_equals.edl` | G707 | `* COMMENT: REEL=G707` |
| `edl_09_comment_tape_equals.edl` | H808 | `* COMMENT: TAPE=H808` |

## Suggested Resolve Test

1. In Project Settings, keep "Extract reel names from EDL comments" enabled.
2. Import all MOVs in `media/` into the Media Pool.
3. Import one EDL from `edl/` as a timeline.
4. Check the timeline clip or matched media pool clip columns for Reel Name /
   Reel Number / Tape Name.
5. Start with `edl_00_reel_column_control.edl`. If this control file does not
   show reel names, the issue is probably not the comment syntax.

