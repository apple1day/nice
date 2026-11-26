#!/usr/bin/env bash
# Make an SDR playback comparison without writing to the original movie.
set -euo pipefail

usage() {
  echo '用法：bash ios/tools/vr-compatible-copy.sh [--start 时间] [--full] [--source-sample | --hvc1-sample | --hvc1-full] [--output-dir 目录] [原片路径]'
  echo '--hvc1-sample 仅生成普通 HEVC/hev1 MP4 的 30 秒原编码与 hvc1 对照，无需重新编码；--hvc1-full 处理整片。'
  echo '默认从指定位置制作 30 秒 4K 兼容片段。未指定原片时，Mac 会打开文件选择窗口。'
}

start=0
full=false
source_sample=false
hvc1_mode=""
destination="$HOME/Movies"
input=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --start|--output-dir)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      if [[ "$1" == --start ]]; then start=$2; else destination=$2; fi
      shift 2 ;;
    --full) full=true; shift ;;
    --source-sample) source_sample=true; shift ;;
    --hvc1-sample|--hvc1-full) [[ -z "$hvc1_mode" ]] || { usage >&2; exit 2; }; hvc1_mode=$1; shift ;;
    --help|-h) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [[ -z "$input" ]] || { usage >&2; exit 2; }; input=$1; shift ;;
  esac
done
for tool in ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo '需要 FFmpeg，在有 Homebrew 的 Mac 上可运行 brew install ffmpeg。' >&2; exit 1; }
done
if [[ -z "$input" ]]; then
  [[ $(uname -s) == Darwin ]] || { usage >&2; exit 2; }
  input=$(osascript -e 'POSIX path of (choose file with prompt "选择 360° 左右分屏 SDR 原片")')
fi
[[ -f "$input" && -r "$input" ]] || { echo '找不到可读取的原片。' >&2; exit 1; }
[[ "$input" == /* ]] || input="$PWD/$input"
if $full && { [[ "$start" != 0 ]] || $source_sample; }; then
  echo '--full 用于转换整片，请单独使用。' >&2
  exit 2
fi
if [[ -n "$hvc1_mode" ]]; then
  if $full || $source_sample || { [[ "$hvc1_mode" == --hvc1-full ]] && [[ "$start" != 0 ]]; }; then
    usage >&2; exit 2
  fi
  if [[ "$hvc1_mode" == --hvc1-full ]]; then start=full; fi
  mkdir -p "$destination"
  folder=$(mktemp -d "${destination%/}/NiceVideos-VR-XXXXXXXX")
  python3 "$(dirname "$0")/hevc_sample.py" "$input" "$start" "$folder" || { rmdir "$folder" 2>/dev/null || true; exit 1; }
  exit 0
fi
transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of csv=p=0 "$input")
case "$transfer" in
  *smpte2084*|*arib-std-b67*) echo '这部原片是 HDR，本脚本只转换 SDR 影片。' >&2; exit 1 ;;
esac

mkdir -p "$destination"
folder=$(mktemp -d "${destination%/}/NiceVideos-VR-XXXXXXXX")
partial="$folder/preview.partial.mp4"
trap 'rm -f -- "$partial"' EXIT
streams=(-map 0:v:0 -map '0:a:0?')
if ! $full; then streams=(-t 30 "${streams[@]}"); fi
ffmpeg -hide_banner -loglevel error -stats -nostdin -n -ss "$start" -i "$input" "${streams[@]}" \
  -vf "fps=30000/1001,scale=w='min(3840,iw)':h=-2" \
  -c:v libx264 -preset fast -crf 19 -pix_fmt yuv420p -c:a aac -b:a 160k -movflags +faststart "$partial"
width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$partial")
[[ "$width" =~ ^[1-9][0-9]*$ ]] || { echo '所选位置没有视频画面，请检查影片时长与 --start。' >&2; exit 1; }
mv -- "$partial" "$folder/4K-compat.mp4"
echo "兼容副本：$folder/4K-compat.mp4"
if $source_sample; then
  ffmpeg -hide_banner -loglevel error -nostdin -n -ss "$start" -i "$input" -t 30 \
    -map 0:v:0 -map '0:a:0?' -c copy -movflags +faststart "$partial"
  mv -- "$partial" "$folder/original-codec.mp4"
  echo "保留原编码的对照片段（从附近的关键帧开始）：$folder/original-codec.mp4"
fi
