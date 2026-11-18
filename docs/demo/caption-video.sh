#!/bin/bash
# Burns the captions in docs/demo/captions.txt into the vhs recording and
# writes every output from it:
#   docs/demo/fast-ios-demo.{gif,mp4,webm}, docs/demo/fast-ios-demo-poster.png,
#   docs/demo/fast-ios-demo.vtt (the same text as a WebVTT subtitles track),
#   and the site copies in site/public/.
# captions.txt: one caption per line, "<start s>|<end s>|<text>".
# Usage, from the repository root, after `vhs docs/demo/demo.tape`:
#   docs/demo/caption-video.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
raw="$here/raw/demo-raw.mp4"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$raw")
height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$raw")
band=110

# One PNG per caption, and the overlay chain that shows each only in its time.
inputs=(-i "$raw")
filter="[0:v]pad=${width}:$((height + band)):0:0:color=0x1e1e2e[v0]"
vtt="WEBVTT"$'\n'
n=0
ts() { awk -v s="$1" 'BEGIN { printf "%02d:%02d:%06.3f", int(s/3600), int((s%3600)/60), s - int(s/60)*60 }'; }
while IFS='|' read -r start end text; do
  [ -z "$start" ] && continue
  n=$((n + 1))
  swift "$here/caption.swift" "$text" "$width" "$work/cap$n.png"
  inputs+=(-i "$work/cap$n.png")
  filter+=";[v$((n - 1))][$n:v]overlay=0:$((height + band - 92 - 9)):enable='between(t,$start,$end)'[v$n]"
  vtt+=$'\n'"$n"$'\n'"$(ts "$start") --> $(ts "$end")"$'\n'"$text"$'\n'
done < "$here/captions.txt"

ffmpeg -v error -y "${inputs[@]}" -filter_complex "$filter" -map "[v$n]" \
  -c:v libx264 -preset slow -crf 24 -pix_fmt yuv420p -movflags +faststart "$here/fast-ios-demo.mp4"
ffmpeg -v error -y -i "$here/fast-ios-demo.mp4" -c:v libvpx-vp9 -b:v 0 -crf 40 -row-mt 1 "$here/fast-ios-demo.webm"
# GIF for the README: 10 fps, 1280 wide, one palette for the whole clip.
ffmpeg -v error -y -i "$here/fast-ios-demo.mp4" \
  -vf "fps=10,scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  "$here/fast-ios-demo.gif"
# Poster: the last frame, with its caption.
ffmpeg -v error -y -sseof -0.5 -i "$here/fast-ios-demo.mp4" -frames:v 1 "$here/fast-ios-demo-poster.png"
printf '%s' "$vtt" > "$here/fast-ios-demo.vtt"

cp "$here/fast-ios-demo.mp4" "$here/fast-ios-demo.webm" "$here/fast-ios-demo.vtt" "$repo/site/public/"
cwebp -quiet -q 85 "$here/fast-ios-demo-poster.png" -o "$repo/site/public/demo-poster.webp"
ls -l "$here"/fast-ios-demo.* "$here/fast-ios-demo-poster.png" "$repo/site/public/demo-poster.webp"
