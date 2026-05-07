#!/usr/bin/env bash
set -euo pipefail

node scripts/generate_demo_cast.mjs

npx --yes svg-term-cli \
  --in assets/demo/interactive-demo.cast \
  --out assets/demo/interactive-demo-readable.svg \
  --width 112 \
  --height 32 \
  --window \
  --padding 12

cp assets/demo/interactive-demo-readable.svg assets/demo/interactive-demo.svg

agg \
  --quiet \
  --theme github-dark \
  --cols 112 \
  --rows 32 \
  --fps-cap 30 \
  --last-frame-duration 4 \
  assets/demo/interactive-demo.cast \
  assets/demo/interactive-demo.gif

ffmpeg \
  -loglevel error \
  -y \
  -i assets/demo/interactive-demo.gif \
  -movflags faststart \
  -pix_fmt yuv420p \
  -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" \
  assets/demo/interactive-demo.mp4

ffmpeg \
  -loglevel error \
  -y \
  -ss 16 \
  -i assets/demo/interactive-demo.mp4 \
  -vframes 1 \
  assets/demo/interactive-demo-poster.png
