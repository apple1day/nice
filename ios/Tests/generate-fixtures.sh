#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/Fixtures"
command -v ffmpeg >/dev/null || { echo '测试样片需要 ffmpeg：brew install ffmpeg'; exit 1; }
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=160x90:rate=12' -f lavfi -i 'sine=frequency=440:sample_rate=44100' \
  -t 3 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart offline.mp4
ffmpeg -hide_banner -loglevel error -y -i offline.mp4 -map 0:a:0 -c copy -movflags +faststart audio-only.mp4
ffmpeg -hide_banner -loglevel error -y -i offline.mp4 -c:v mpeg4 -q:v 5 -c:a copy offline.mkv
python3 ../../tools/make_large_mp4_fixture.py offline.mp4
# Each eye has an unambiguous color so a decoder test can detect eye/channel swaps.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=c=red:size=128x96:rate=12' -f lavfi -i 'color=c=blue:size=128x96:rate=12' \
  -filter_complex 'hstack,setsar=3/2' -t 2 -c:v libx264 -pix_fmt yuv420p -movflags +faststart sbs.mp4
# Generated in the UI-test target only. Every second both eye colors change.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'color=red:size=320x180:rate=8' -f lavfi -i 'color=blue:size=320x180:rate=8' \
  -filter_complex "[0:v]drawbox=c=lime:t=fill:enable='gte(mod(t,2),1)'[l];[1:v]drawbox=c=yellow:t=fill:enable='gte(mod(t,2),1)'[r];[l][r]hstack" \
  -t 90 -c:v libx264 -g 8 -pix_fmt yuv420p -movflags +faststart ../../UITests/moving-stereo.mp4
# The decoder sees 4K HEVC at 24 fps. Encode one two-second cycle and remux
# it for three minutes so the ordinary → SBS → ordinary checks retain moving
# frames even when simulator gestures and screenshots take over a minute.
pattern_dir="$(mktemp -d)"
trap 'rm -rf "$pattern_dir"' EXIT
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=red:size=3840x2160:rate=24,drawbox=x=1920:y=0:w=1920:h=2160:c=blue:t=fill,drawbox=x=0:y=0:w=1920:h=2160:c=lime:t=fill:enable='gte(t,1)',drawbox=x=1920:y=0:w=1920:h=2160:c=yellow:t=fill:enable='gte(t,1)'" \
  -t 2 -c:v libx265 -preset ultrafast -x265-params 'pools=2:frame-threads=2:keyint=24:min-keyint=24:scenecut=0:log-level=error' \
  -pix_fmt yuv420p -tag:v hvc1 "$pattern_dir/cycle.mp4"
ffmpeg -hide_banner -loglevel error -y -stream_loop 89 -i "$pattern_dir/cycle.mp4" \
  -f lavfi -i 'anullsrc=sample_rate=48000:channel_layout=mono' -map 0:v:0 -map 1:a:0 \
  -t 180 -c:v copy -tag:v hvc1 -c:a aac -b:a 32k -movflags +faststart "$pattern_dir/indexed.mp4"
python3 ../../tools/make_large_mp4_fixture.py "$pattern_dir/indexed.mp4" ../../UITests/moving4k
# Eight seconds at the reported coded width with one 360° image per eye.
# Encode a two-second red/blue → green/yellow cycle and repeat the encoded GOPs.
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "color=red:size=512x128:rate=24,drawbox=x=256:w=256:h=128:c=blue:t=fill,drawbox=x=0:w=256:h=128:c=lime:t=fill:enable='gte(t,1)',drawbox=x=256:w=256:h=128:c=yellow:t=fill:enable='gte(t,1)',scale=8192:2048:flags=neighbor" \
  -t 2 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 \
  -x265-params 'pools=2:frame-threads=2:keyint=24:min-keyint=24:scenecut=0:log-level=error' "$pattern_dir/eyes8k.mp4"
ffmpeg -hide_banner -loglevel error -y -stream_loop 3 -i "$pattern_dir/eyes8k.mp4" \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -map 0:v:0 -map 1:a:0 \
  -t 8 -c:v copy -tag:v hvc1 -c:a aac -movflags +faststart stereo8k-replay.mp4
# Full-height 8K at 60000/1001, matching the dimensions and time base of the
# field report. Encode just six frames per color pair, then repeat closed GOPs.
for pair in red-blue lime-yellow; do
  left="${pair%-*}"
  right="${pair#*-}"
  ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i "color=$left:s=256x128:r=60000/1001,drawbox=x=128:y=0:w=128:h=128:c=$right:t=fill,scale=8192:4096:flags=neighbor" \
    -frames:v 6 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 \
    -x265-params 'pools=1:frame-threads=1:bframes=0:ref=1:keyint=6:log-level=error' "$pattern_dir/$pair.mp4"
done
# Change both eyes after 6 or 12 frames so a slow decoder can expose motion
# before either clock reaches EOF. The Main 10 keyframes at 0 and 30 also differ.
for pair in red-blue lime-yellow red-blue red-blue lime-yellow \
            lime-yellow red-blue lime-yellow lime-yellow red-blue; do
  echo "file '$pair.mp4'"
  echo "duration 0.100100"
done > "$pattern_dir/full8k.txt"
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i "$pattern_dir/full8k.txt" \
  -c copy -tag:v hvc1 "$pattern_dir/full8k-cycle.mp4"
ffmpeg -hide_banner -loglevel error -y -stream_loop 11 -i "$pattern_dir/full8k-cycle.mp4" \
  -f lavfi -i 'anullsrc=sample_rate=48000:channel_layout=mono' -map 0:v:0 -map 1:a:0 \
  -t 12 -c:v copy -tag:v hvc1 -c:a aac -b:a 32k -movflags +faststart stereo8k60-full.mp4
python3 ../../tools/make_large_mp4_fixture.py stereo8k60-full.mp4 full8k-co64
# The offline converter must accept Main 10 tagged hev1, retain the packed eyes
# and preserve real audio. Encode one short cycle and reuse its closed GOPs.
ffmpeg -hide_banner -loglevel error -y -i "$pattern_dir/full8k-cycle.mp4" \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -profile:v main10 \
  -x265-params 'pools=2:frame-threads=2:keyint=30:min-keyint=30:open-gop=0:scenecut=0:log-level=error' \
  -tag:v hev1 "$pattern_dir/main10-cycle.mp4"
ffmpeg -hide_banner -loglevel error -y -stream_loop 7 -i "$pattern_dir/main10-cycle.mp4" \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -map 0:v:0 -map 1:a:0 \
  -t 8 -c:v copy -tag:v hev1 -c:a aac -b:a 64k -movflags +faststart vr8k-main10-hev1.mp4
# A directional stereo panorama with independent eye colors, video motion and
# a continuous audible tone. Encode a short GOP once and reuse it in the UI test.
ffmpeg -hide_banner -loglevel error -y -f lavfi \
  -i "color=black:s=384x192:r=12,format=gbrp,geq=r='32+192*mod(X,192)/191':g='32+192*Y/191':b='36+128*gte(X,192)+42*gte(mod(N,24),12)'" \
  -t 2 -c:v libx264 -threads 2 -g 12 -bf 0 -pix_fmt yuv420p "$pattern_dir/panorama.mp4"
ffmpeg -hide_banner -loglevel error -y -stream_loop 29 -i "$pattern_dir/panorama.mp4" \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100' -map 0:v:0 -map 1:a:0 \
  -t 60 -c:v copy -c:a aac -b:a 32k -movflags +faststart panorama-audio.mp4
# Keep the ZLIB-compressed launch environment small. The UI gestures check
# projection and frame motion; actual decoded audio is measured in the hosted test.
ffmpeg -hide_banner -loglevel error -y -i panorama-audio.mp4 -map 0:v:0 -c copy \
  -movflags +faststart ../../UITests/panorama-chart.mp4
