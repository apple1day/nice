# Local-only generated test media

`../generate-fixtures.sh` creates a 3-second synthetic test pattern with audio,
encoded as H.264/AAC MP4 and MPEG-4 Part 2/AAC MKV. There is no downloaded media,
user video, or third-party movie in these fixtures. Generated binaries are ignored.

The same script generates a two-second SBS MP4 with a solid red left eye and
a solid blue right eye for the decoded-pixel checks.

`fragmented.mp4` contains the video track from the three-second test pattern
with fragment-relative offsets. `PickedFilePlaybackTests` inserts a 4 GiB
sparse MP4 `free` box after `ftyp` when the test runs. A decoder must seek
beyond the 32-bit offset range to read the video, while the test only writes
the small fixture and a box header. The test opens this file through the
Files playback path and checks both the native video output and the VR decoder.
