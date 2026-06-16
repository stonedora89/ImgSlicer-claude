#!/usr/bin/env bash
# Score the detector against the manual corrections you made in the app.
#
# How the feedback loop works:
#   1. In ImgSlicer, fix the crop boxes on any image that looks wrong and switch
#      away — the app saves your correction to <folder>/.imgslicer-edits.json.
#   2. Run this script. It compares the detector's output to your corrections
#      (IoU per box, in normalized coordinates) and lists the worst images.
#   3. Those scores tell us exactly what to improve — and re-running after a
#      change shows whether it helped without silently breaking other images.
#
# Usage: bash scripts/benchmark.sh [image-folder] [profile]
#   image-folder  defaults to ./imgs
#   profile       filmScan (default) | gridPhoto | balanced
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FOLDER="${1:-$ROOT_DIR/imgs}"
PROFILE="${2:-filmScan}"

cd "$ROOT_DIR"
echo "Building release binary..."
swift build -c release >/dev/null

export IMGSLICER_PYTHON="${IMGSLICER_PYTHON:-$ROOT_DIR/.venv/bin/python3}"
export IMGSLICER_DETECTOR_SCRIPT="${IMGSLICER_DETECTOR_SCRIPT:-$ROOT_DIR/Sources/ImgSlicer/Resources/detectors/opencv_detector.py}"

.build/release/ImgSlicer --benchmark "$FOLDER" --profile "$PROFILE"
