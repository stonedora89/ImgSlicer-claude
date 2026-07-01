#!/usr/bin/env python3
"""End-to-end check: model mask → connected-component boxes → box IoU vs truth.

Mask IoU (pixel overlap) flatters the model; what matters for cropping is the
BOX. This runs the trained U-Net, thresholds the mask, labels connected
components (each photo frame is one blob separated by black gutter), turns each
into a box, and scores box IoU against the hand-corrected manual boxes. It is
the honest test of whether the DL path can approach the heuristic's 0.979.

The Swift integration will instead feed these raw boxes into the existing
grid-regularization passes; here we measure the raw component boxes so we can see
how much the post-processing needs to do.
"""
import json, warnings
warnings.filterwarnings("ignore")
import numpy as np
from PIL import Image
import torch
import scipy.ndimage as ndi
from train import UNet, ROOT, DEV

SRC = "/Users/howell/work/ImgSlicer-claude/分割测试"


def iou(a, b):
    ix = max(0, min(a["x"]+a["width"], b["x"]+b["width"]) - max(a["x"], b["x"]))
    iy = max(0, min(a["y"]+a["height"], b["y"]+b["height"]) - max(a["y"], b["y"]))
    i = ix*iy
    u = a["width"]*a["height"] + b["width"]*b["height"] - i
    return i/u if u > 0 else 0


def mask_to_boxes(prob, H, W):
    binary = prob > 0.5
    binary = ndi.binary_opening(binary, iterations=2)  # drop specks/bridges
    lbl, n = ndi.label(binary)
    boxes = []
    for i in range(1, n+1):
        ys, xs = np.where(lbl == i)
        if len(xs) < 0.002 * H * W:   # ignore tiny blobs
            continue
        x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
        bw, bh = (x1-x0)/W, (y1-y0)/H
        if bw < 0.03 or bh < 0.03:
            continue
        boxes.append({"x": x0/W, "y": y0/H, "width": bw, "height": bh})
    return boxes


def main():
    net = UNet().to(DEV)
    net.load_state_dict(torch.load(f"{ROOT}/unet.pt", map_location=DEV))
    net.eval()
    edits = json.load(open(f"{SRC}/.imgslicer-edits.json"))

    tot_iou = tot_cnt_ok = n = 0
    for key, p in edits["photos"].items():
        if not p.get("hasLocalOverrides"):
            continue
        manual = p.get("manualRegions") or []
        if not manual:
            continue
        stem = key.replace("/", "__").replace(" ", "_").rsplit(".", 1)[0]
        img = np.asarray(Image.open(f"{ROOT}/data/images/{stem}.png").convert("L"), np.float32)/255
        H, W = img.shape
        ip = np.pad(img, ((0, (-H) % 32), (0, (-W) % 32)))
        with torch.no_grad():
            prob = torch.sigmoid(net(torch.from_numpy(ip)[None, None].to(DEV)))[0, 0].cpu().numpy()[:H, :W]
        boxes = mask_to_boxes(prob, H, W)
        # greedy box IoU vs manual
        used, s = set(), 0
        for m in manual:
            best, bi = 0, -1
            for i, b in enumerate(boxes):
                if i in used:
                    continue
                v = iou(b, m)
                if v > best:
                    best, bi = v, i
            if bi >= 0:
                used.add(bi); s += best
        mean = s/len(manual)
        cnt_ok = len(boxes) == len(manual)
        tot_iou += mean; tot_cnt_ok += cnt_ok; n += 1
        print(f"  {key}: {len(boxes)} boxes vs {len(manual)} manual | box IoU {mean:.3f}{' ✓cnt' if cnt_ok else ''}")
    print(f"\nRaw component boxes (no grid post-proc): mean box IoU {tot_iou/n:.3f}, count-match {tot_cnt_ok}/{n}")
    print("(heuristic detector is 0.979; the gap here is what Swift grid post-processing must close)")


if __name__ == "__main__":
    main()
