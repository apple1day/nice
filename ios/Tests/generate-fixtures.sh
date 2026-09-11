#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/Fixtures"
command -v ffmpeg >/dev/null || { echo '测试样片需要 ffmpeg：brew install ffmpeg'; exit 1; }
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=160x90:rate=12' -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart offline.mp4
ffmpeg -hide_banner -loglevel error -y -i offline.mp4 -c:v mpeg4 -q:v 5 -c:a copy offline.mkv
