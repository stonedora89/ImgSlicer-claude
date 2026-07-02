#!/usr/bin/env python3
"""Test whether the retrained model trims black borders PER-FRAME without
cutting into the subject — the two things the user insisted on.

For every hand-corrected scan: run the model → component boxes → grid
post-processing, match each box to the user's manual box, and measure the top
and bottom edge error (signed, as % of frame height):
    ~0      = matches the user's border-free edge (ideal)
    +large  = OVER-shrunk, cut into the subject  ← the failure to avoid
    -large  = UNDER-shrunk, black border kept

It also reports per-image shrink spread: if the model applied a DIFFERENT trim
to different frames (not a uniform cut), the std of its trims is non-trivial —
evidence it adapted per frame instead of a global shrink.
"""
import json, warnings
warnings.filterwarnings("ignore")
import numpy as np
from PIL import Image
import torch, scipy.ndimage as ndi
import sys; sys.path.insert(0, "ml")
from train import UNet, ROOT, DEV
from mask_to_boxes import mask_to_boxes, iou

SRC = "/Users/howell/work/ImgSlicer-claude/分割测试"


def median(xs):
    return sorted(xs)[len(xs) // 2] if xs else 0


def grid_postprocess(boxes):
    if len(boxes) < 3:
        return boxes
    boxes = [dict(b) for b in boxes]
    mH = median([b["height"] for b in boxes]); rowTol = mH * 0.4

    def rows_of(bs):
        order = sorted(range(len(bs)), key=lambda i: bs[i]["y"] + bs[i]["height"] / 2)
        rows = []
        for i in order:
            cy = bs[i]["y"] + bs[i]["height"] / 2
            if rows and abs(cy - (bs[rows[-1][0]]["y"] + bs[rows[-1][0]]["height"] / 2)) <= rowTol:
                rows[-1].append(i)
            else:
                rows.append([i])
        return rows

    rows = rows_of(boxes)
    if len(rows) >= 2:
        richest = max(rows, key=len)
        if len(richest) >= 3:
            cx = sorted(boxes[i]["x"] + boxes[i]["width"] / 2 for i in richest)
            gaps = [cx[i + 1] - cx[i] for i in range(len(cx) - 1)]
            pitch = median(gaps); mW = median([boxes[i]["width"] for i in richest])
            if mW * 0.85 < pitch < mW * 1.8 and all(pitch * 0.8 < g < pitch * 1.2 for g in gaps):
                originX = cx[0]; ncol = len(richest); out = []
                for b in boxes:
                    c0 = round((b["x"] + b["width"] * 0.15 - originX) / pitch)
                    c1 = round((b["x"] + b["width"] * 0.85 - originX) / pitch)
                    span = c1 - c0 + 1
                    if 2 <= span <= ncol and b["width"] >= pitch * (span - 0.5) and b["width"] <= pitch * (span + 0.4):
                        for k in range(span):
                            c = c0 + k
                            l = (originX + c * pitch - pitch / 2) if k > 0 else b["x"]
                            r = (originX + c * pitch + pitch / 2) if k < span - 1 else b["x"] + b["width"]
                            out.append({"x": l, "y": b["y"], "width": r - l, "height": b["height"]})
                    else:
                        out.append(b)
                boxes = out
    for row in rows_of(boxes):
        if len(row) < 3:
            continue
        mT = median([boxes[i]["y"] for i in row]); mB = median([boxes[i]["y"] + boxes[i]["height"] for i in row])
        rh = mB - mT
        if rh <= 0:
            continue
        cons = sum(1 for i in row if abs(boxes[i]["y"] - mT) < rh * 0.12 and abs(boxes[i]["y"] + boxes[i]["height"] - mB) < rh * 0.12)
        if cons < len(row) * 0.5:
            continue
        for i in row:
            t = boxes[i]["y"]; b = boxes[i]["y"] + boxes[i]["height"]
            boxes[i]["y"] = mT if abs(t - mT) > rh * 0.12 else t
            boxes[i]["height"] = (mB if abs(b - mB) > rh * 0.12 else b) - boxes[i]["y"]
    return boxes


def main():
    net = UNet().to(DEV)
    net.load_state_dict(torch.load(f"{ROOT}/unet.pt", map_location=DEV))
    net.eval()
    edits = json.load(open(f"{SRC}/.imgslicer-edits.json"))

    tot_iou = n = 0
    top_errs, bot_errs = [], []
    over = under = 0
    per_img_top_std = []
    for key, p in edits["photos"].items():
        if not p.get("hasLocalOverrides"):
            continue
        manual = p.get("manualRegions") or []
        if not manual:
            continue
        stem = key.replace("/", "__").replace(" ", "_").rsplit(".", 1)[0]
        img = np.asarray(Image.open(f"{ROOT}/data/images/{stem}.png").convert("L"), np.float32) / 255
        H, W = img.shape
        ip = np.pad(img, ((0, (-H) % 32), (0, (-W) % 32)))
        with torch.no_grad():
            prob = torch.sigmoid(net(torch.from_numpy(ip)[None, None].to(DEV)))[0, 0].cpu().numpy()[:H, :W]
        boxes = grid_postprocess(mask_to_boxes(prob, H, W))
        used, s, img_tops = set(), 0, []
        for m in manual:
            best, bi = 0, -1
            for i, b in enumerate(boxes):
                if i in used:
                    continue
                v = iou(b, m)
                if v > best:
                    best, bi = v, i
            if bi < 0:
                continue
            used.add(bi); s += best
            te = (boxes[bi]["y"] - m["y"]) / m["height"]          # +over/cut-in, -under/border
            be = ((m["y"] + m["height"]) - (boxes[bi]["y"] + boxes[bi]["height"])) / m["height"]
            top_errs.append(te); bot_errs.append(be); img_tops.append(te)
            if te > 0.03 or be > 0.03:
                over += 1
            if te < -0.03 or be < -0.03:
                under += 1
        tot_iou += s / len(manual); n += 1
        if len(img_tops) > 1:
            per_img_top_std.append(np.std(img_tops))

    matched = len(top_errs)
    print(f"Retrained model — {n} scans, {matched} matched frames")
    print(f"  mean box IoU: {tot_iou/n:.3f}")
    print(f"  top edge err: {np.mean(top_errs)*100:+.2f}% (~0 ideal, + = cut subject, - = border)")
    print(f"  bottom err:   {np.mean(bot_errs)*100:+.2f}%")
    print(f"  OVER-shrunk frames (cut into subject >3%): {over}/{matched}  ← must stay low")
    print(f"  UNDER-shrunk frames (border kept >3%):     {under}/{matched}")
    print(f"  per-image top-trim spread (std): {np.mean(per_img_top_std)*100:.2f}% "
          f"({'per-frame adaptive' if np.mean(per_img_top_std) > 0.005 else 'nearly uniform'})")


if __name__ == "__main__":
    main()
