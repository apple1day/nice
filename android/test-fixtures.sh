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
  # Give the gesture tests a continuous audible track across the looped video.
  ffmpeg -nostdin -v error -y -stream_loop 29 -i "$work/$packing.mp4" \
    -f lavfi -i 'sine=frequency=440:sample_rate=44100' -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a aac -t 60 -movflags +faststart "$dest/vr-chart-$packing.mp4"
done

# A moving marker traverses each eye at 30 fps. Encode one full animation,
# then repeat its GOPs against an uninterrupted mono tone in the HD file.
ffmpeg -nostdin -v error -y -f lavfi \
  -i "color=black:s=384x192:r=30,format=gbrp,geq=r='32+192*mod(X,192)/191':g='32+192*Y/191':b='36+128*gte(X,192)+42*gte(mod(N,60),30)+32*lt(Y,28)*lt(abs(mod(X,192)-3*N),6)'" \
  -t 2 -vf 'scale=1920:960:flags=bilinear' -c:v libx264 -threads 2 -preset ultrafast \
  -pix_fmt yuv420p -g 30 -bf 0 -an "$work/avc-hd.mp4"
ffmpeg -nostdin -v error -y -stream_loop 14 -i "$work/avc-hd.mp4" \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -map 0:v:0 -map 1:a:0 -t 30 \
  -c:v copy -c:a aac -movflags +faststart "$dest/vr-chart-avc-hd.mp4"

# Use the same moving coordinate chart at a common decoder size and at 4K.
# The two-second HEVC GOP can be repeated without re-encoding the test movie.
for variant in hevc-hd hevc; do
  if [[ "$variant" == hevc-hd ]]; then scale=1280:640; else scale=3840:1920; fi
  ffmpeg -nostdin -v error -y -i "$dest/vr-chart-sbs.mp4" -t 2 -vf "fps=4,scale=$scale:flags=bilinear" \
    -c:v libx265 -threads 2 -preset ultrafast \
    -x265-params 'pools=2:frame-threads=2:keyint=4:min-keyint=4:scenecut=0:bframes=0:log-level=error' \
    -pix_fmt yuv420p -tag:v hvc1 -an "$work/$variant.mp4"
  ffmpeg -nostdin -v error -y -stream_loop 11 -i "$work/$variant.mp4" -f lavfi -i 'anullsrc=r=44100:cl=mono' \
    -map 0:v:0 -map 1:a:0 -t 24 -c:v copy -tag:v hvc1 -c:a aac \
    -movflags +faststart "$dest/vr-chart-$variant.mp4"
done

# Include a small VP9 profile-0 chart for devices with software VP9 but no
# software AVC decoder. Check both a successful manual switch and AVC recovery.
ffmpeg -nostdin -v error -y -i "$work/sbs.mp4" -t 2 -c:v libvpx-vp9 -threads 2 \
  -deadline realtime -cpu-used 7 -g 8 -crf 26 -b:v 0 -pix_fmt yuv420p -c:a copy "$work/vp9.mp4"
ffmpeg -nostdin -v error -y -stream_loop 29 -i "$work/vp9.mp4" -t 60 -c copy \
  -movflags +faststart "$dest/vr-chart-vp9.mp4"
