#!/usr/bin/env bash
set -euo pipefail
dest="$1"
helper="$2"
mkdir -p "$dest"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Distinct colors reveal stale frames and swapped eyes in a screen capture.
ffmpeg -nostdin -v error -y -f lavfi \
  -i "color=red:s=320x120:r=8,drawbox=x=160:y=0:w=160:h=120:c=blue:t=fill,drawbox=x=0:y=0:w=160:h=120:c=lime:t=fill:enable='gte(mod(t,2),1)',drawbox=x=160:y=0:w=160:h=120:c=yellow:t=fill:enable='gte(mod(t,2),1)'" \
  -f lavfi -i 'anullsrc=r=44100:cl=mono' -t 90 -c:v libx264 -threads 2 -g 8 \
  -pix_fmt yuv420p -c:a aac -movflags +faststart "$dest/moving-sbs.mp4"
ffmpeg -nostdin -v error -y -f lavfi -i 'testsrc2=size=160x90:rate=12' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 3.2 \
  -c:v libx264 -threads 2 -g 12 -pix_fmt yuv420p -c:a aac -movflags +faststart "$work/short.mp4"
python3 "$helper" "$work/short.mp4"
cp "$work/co64-index.bin" "$work/co64-samples.bin" "$dest/"
