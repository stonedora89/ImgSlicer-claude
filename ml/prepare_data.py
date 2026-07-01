#!/usr/bin/env python3
"""Turn the app's saved crop boxes into a photo-vs-gutter segmentation dataset.

Each contact-sheet scan becomes an (image, mask) pair: mask=1 inside a photo
frame, 0 on the black film gutter. Manual (hand-corrected) boxes are ground
truth; auto boxes are weaker pseudo-labels. A split file records which is which
so training can weight/validate on the trustworthy manual set.
"""
import json, os, warnings
warnings.filterwarnings("ignore")
from PIL import Image, ImageDraw
import numpy as np

ROOT = "/Users/howell/work/ImgSlicer-claude"
SRC = f"{ROOT}/分割测试"
OUT = f"{ROOT}/ml/data"
LONG_SIDE = 1024

def main():
    edits = json.load(open(f"{SRC}/.imgslicer-edits.json"))
    manifest = []
    for key, p in edits["photos"].items():
        folder, fname = key.split("/")
        path = f"{SRC}/{folder}/{fname}"
        if not os.path.exists(path):
            continue
        boxes = p.get("manualRegions") or p.get("autoRegions") or p.get("regions") or []
        if not boxes:
            continue
        is_manual = bool(p.get("hasLocalOverrides"))
        img = Image.open(path).convert("RGB")
        ow, oh = img.size
        scale = LONG_SIDE / max(ow, oh)
        W, H = int(ow * scale), int(oh * scale)
        img = img.resize((W, H), Image.LANCZOS)
        mask = Image.new("L", (W, H), 0)
        dr = ImageDraw.Draw(mask)
        for b in boxes:
            x0, y0 = b["x"] * W, b["y"] * H
            x1, y1 = (b["x"] + b["width"]) * W, (b["y"] + b["height"]) * H
            dr.rectangle([x0, y0, x1, y1], fill=255)
        stem = key.replace("/", "__").replace(" ", "_").rsplit(".", 1)[0]
        img.save(f"{OUT}/images/{stem}.png")
        mask.save(f"{OUT}/masks/{stem}.png")
        manifest.append({"stem": stem, "manual": is_manual, "frames": len(boxes), "size": [W, H]})
    json.dump(manifest, open(f"{OUT}/manifest.json", "w"), ensure_ascii=False, indent=2)
    nm = sum(1 for m in manifest if m["manual"])
    print(f"Wrote {len(manifest)} image/mask pairs ({nm} manual GT, {len(manifest)-nm} pseudo)")

if __name__ == "__main__":
    main()
