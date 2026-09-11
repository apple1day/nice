#!/usr/bin/env bash
# Rebuild generated project metadata only; never uninstall or erase App data.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
bash "$root/setup.sh"
open "$root/NiceVideos.xcworkspace"
