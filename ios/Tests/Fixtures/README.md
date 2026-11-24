# Local-only generated test media

`../generate-fixtures.sh` creates a 3-second synthetic test pattern with audio,
encoded as H.264/AAC MP4 and MPEG-4 Part 2/AAC MKV. There is no downloaded media,
user video, or third-party movie in these fixtures. Generated binaries are ignored.

The same script generates a two-second SBS MP4 with a solid red left eye and
a solid blue right eye for the decoded-pixel checks.

`co64-index.bin` and `co64-samples.bin` are the two populated regions of a
faststart MP4 with both video and audio, generated from four loops of the test
pattern. The index contains the full movie metadata, 64-bit chunk offsets for
both tracks, and a 64-bit media-data box header. `PickedFilePlaybackTests`
writes the index at the start and the samples at the 4 GiB boundary. The sparse
hole consumes no disk space. The test opens this file through the Files playback
path, seeks, and checks both the native video output and the VR decoder.
