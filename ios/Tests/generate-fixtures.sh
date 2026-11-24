#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/Fixtures"
command -v ffmpeg >/dev/null || { echo '测试样片需要 ffmpeg：brew install ffmpeg'; exit 1; }
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=160x90:rate=12' -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart offline.mp4
ffmpeg -hide_banner -loglevel error -y -i offline.mp4 -c:v mpeg4 -q:v 5 -c:a copy offline.mkv
# Fragment-relative offsets stay valid when the test inserts a sparse free box.
ffmpeg -hide_banner -loglevel error -y -i offline.mp4 -map 0:v:0 -c copy \
  -movflags +empty_moov+frag_keyframe+default_base_moof+skip_trailer fragmented.mp4
# Each eye has an unambiguous color so a decoder test can detect eye/channel swaps.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=red:size=128x96:rate=12' -f lavfi -i 'color=c=blue:size=128x96:rate=12' \
  -filter_complex 'hstack,setsar=3/2' -t 2 -c:v libx264 -pix_fmt yuv420p -movflags +faststart sbs.mp4
