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

# Each square eye is a directional coordinate chart: red = longitude, green =
# latitude, blue = eye identity plus a one-second pulse. This distinguishes a
# moving panorama from a correctly colored but stationary or mirrored frame.
for packing in sbs tb; do
  if [[ "$packing" == sbs ]]; then
    size=384x192
    eye='gte(X,192)'
  else
    size=192x384
    eye='gte(Y,192)'
  fi
  ffmpeg -nostdin -v error -y -f lavfi \
    -i "color=black:s=$size:r=8,format=gbrp,geq=r='32+192*mod(X,192)/191':g='32+192*mod(Y,192)/191':b='36+128*$eye+42*gte(mod(N,16),8)'" \
    -f lavfi -i 'anullsrc=r=44100:cl=mono' -t 2 -c:v libx264 -threads 2 -g 8 -bf 0 \
    -pix_fmt yuv420p -c:a aac "$work/$packing.mp4"
  ffmpeg -nostdin -v error -y -stream_loop 29 -i "$work/$packing.mp4" -c copy -t 60 \
    -movflags +faststart "$dest/vr-chart-$packing.mp4"
done

# Exercise a real 3840x1920 HEVC bitstream in the system codec. Scale the
# coordinate chart before encoding; repeat the short GOP without transcoding.
ffmpeg -nostdin -v error -y -i "$dest/vr-chart-sbs.mp4" -t 2 -vf 'fps=4,scale=3840:1920:flags=bilinear' \
  -c:v libx265 -threads 2 -preset ultrafast \
  -x265-params 'pools=2:frame-threads=2:keyint=4:min-keyint=4:scenecut=0:bframes=0:log-level=error' \
  -pix_fmt yuv420p -tag:v hvc1 -c:a aac "$work/4k.mp4"
ffmpeg -nostdin -v error -y -stream_loop 11 -i "$work/4k.mp4" -t 24 -c copy -tag:v hvc1 \
  -movflags +faststart "$dest/vr-chart-hevc.mp4"
