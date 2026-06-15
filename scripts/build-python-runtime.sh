#!/usr/bin/env bash
# Build the self-contained, relocatable Python runtime that ships inside
# ImgSlicer.app and powers the OpenCV detector.
#
# The result lives at vendor/python-standalone/ (gitignored). package-mac.sh
# copies it into the app bundle. Rerun this when you need to recreate or
# upgrade the bundled Python / OpenCV.
#
# Requirements: uv (https://docs.astral.sh/uv/). Apple Silicon only — the app
# binary is arm64-only, so the runtime is too.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY_VERSION="3.12"
DEST="$ROOT_DIR/vendor/python-standalone"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv not found. Install from https://docs.astral.sh/uv/ first." >&2
  exit 1
fi

echo "Installing standalone CPython $PY_VERSION via uv..."
uv python install "$PY_VERSION"
SRC="$(dirname "$(dirname "$(uv python find "$PY_VERSION")")")"

echo "Vendoring runtime into $DEST ..."
mkdir -p "$ROOT_DIR/vendor"
rm -rf "$DEST"
ditto "$SRC" "$DEST"

# Make the copy writable/installable: drop the managed + PEP 668 markers.
find "$DEST" -name "EXTERNALLY-MANAGED" -delete

PYBIN="$DEST/bin/python3"
echo "Installing OpenCV + numpy into the vendored runtime..."
"$PYBIN" -m pip install --no-input --upgrade opencv-python-headless numpy

echo "Verifying it runs self-contained..."
"$PYBIN" -c "import cv2, numpy; print('cv2', cv2.__version__, 'numpy', numpy.__version__)"

echo "Done: $DEST"
