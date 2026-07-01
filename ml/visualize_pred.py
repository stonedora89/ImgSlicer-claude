#!/usr/bin/env python3
"""Overlay the trained U-Net's photo-vs-gutter prediction on a scan.

Run after train.py. Green = predicted photo area. Lets us eyeball whether the
model learned real photo-vs-gutter SEMANTICS — especially on dark frames, where
the heuristic detector fails — rather than just echoing bright/dark thresholds.

    python3 ml/visualize_pred.py 分割5__图像_001
"""
import sys, warnings
warnings.filterwarnings("ignore")
import numpy as np
from PIL import Image
import torch
from train import UNet, ROOT, DEV


def main():
    stem = sys.argv[1] if len(sys.argv) > 1 else "分割5__图像_001"
    net = UNet().to(DEV)
    net.load_state_dict(torch.load(f"{ROOT}/unet.pt", map_location=DEV))
    net.eval()

    img = Image.open(f"{ROOT}/data/images/{stem}.png").convert("RGB")
    g = np.asarray(img.convert("L"), np.float32) / 255
    H, W = g.shape
    gp = np.pad(g, ((0, (-H) % 32), (0, (-W) % 32)))
    with torch.no_grad():
        t = torch.from_numpy(gp)[None, None].to(DEV)
        p = torch.sigmoid(net(t))[0, 0].cpu().numpy()[:H, :W]

    a = np.asarray(img).copy()
    fg = p > 0.5
    a[fg] = (a[fg] * 0.55 + np.array([0, 255, 0]) * 0.45).astype("uint8")
    out = f"/tmp/pred_{stem}.jpg"
    Image.fromarray(a).save(out)
    print(f"saved {out}  (foreground pixels: {fg.mean()*100:.1f}%)")


if __name__ == "__main__":
    main()
