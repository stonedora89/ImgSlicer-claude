#!/usr/bin/env python3
"""Train a light U-Net to segment photo frames from film gutter.

Deliberately small (few conv blocks) to fit the tiny dataset, trained on random
256×256 patches with heavy augmentation to squeeze samples out of 45 scans.
Manual-labelled scans are held out for validation so the score reflects real
ground truth, not the auto pseudo-labels. This is the training half of the DL
pipeline; inference/export is separate. NOTE: with only 8 manual scans this can
at best distil the existing 0.979 detector — it cannot exceed it until far more
hand-corrected scans are accumulated.
"""
import json, os, random, warnings
warnings.filterwarnings("ignore")
import numpy as np
from PIL import Image
import torch, torch.nn as nn, torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

ROOT = "/Users/howell/work/ImgSlicer-claude/ml"
DEV = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
PATCH = 256

class SegSet(Dataset):
    def __init__(self, stems, train=True):
        self.stems, self.train = stems, train
    def __len__(self): return len(self.stems) * (20 if self.train else 1)
    def __getitem__(self, i):
        stem = self.stems[i % len(self.stems)]
        img = np.asarray(Image.open(f"{ROOT}/data/images/{stem}.png").convert("L"), np.float32) / 255
        msk = np.asarray(Image.open(f"{ROOT}/data/masks/{stem}.png").convert("L"), np.float32) / 255
        H, W = img.shape
        if self.train:
            y = random.randint(0, max(0, H - PATCH)); x = random.randint(0, max(0, W - PATCH))
            img = img[y:y+PATCH, x:x+PATCH]; msk = msk[y:y+PATCH, x:x+PATCH]
            img = np.pad(img, ((0, PATCH-img.shape[0]), (0, PATCH-img.shape[1])))
            msk = np.pad(msk, ((0, PATCH-msk.shape[0]), (0, PATCH-msk.shape[1])))
            if random.random() < .5: img, msk = img[:, ::-1].copy(), msk[:, ::-1].copy()
            if random.random() < .5: img = np.clip(img * random.uniform(.6, 1.4), 0, 1)
        else:
            img = np.pad(img, ((0, (-H) % 32), (0, (-W) % 32))); msk = np.pad(msk, ((0, (-H) % 32), (0, (-W) % 32)))
        return torch.from_numpy(img)[None], torch.from_numpy(msk)[None]

def block(i, o): return nn.Sequential(nn.Conv2d(i, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(),
                                      nn.Conv2d(o, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU())
class UNet(nn.Module):
    def __init__(s, c=16):
        super().__init__()
        s.d1, s.d2, s.d3 = block(1, c), block(c, c*2), block(c*2, c*4)
        s.p = nn.MaxPool2d(2)
        s.u2 = nn.ConvTranspose2d(c*4, c*2, 2, 2); s.c2 = block(c*4, c*2)
        s.u1 = nn.ConvTranspose2d(c*2, c, 2, 2); s.c1 = block(c*2, c)
        s.out = nn.Conv2d(c, 1, 1)
    def forward(s, x):
        a = s.d1(x); b = s.d2(s.p(a)); c = s.d3(s.p(b))
        y = s.c2(torch.cat([s.u2(c), b], 1)); y = s.c1(torch.cat([s.u1(y), a], 1))
        return s.out(y)

def dice(p, t): p = torch.sigmoid(p); return 1 - (2*(p*t).sum()+1)/(p.sum()+t.sum()+1)

def main():
    man = json.load(open(f"{ROOT}/data/manifest.json"))
    manual = [m["stem"] for m in man if m["manual"]]
    pseudo = [m["stem"] for m in man if not m["manual"]]
    random.seed(0); random.shuffle(manual)
    # The auto pseudo-labels include black borders; the hand-corrected manual
    # labels have them trimmed. Up-weight manual 6× so the model learns the
    # user's tight, border-free edges rather than averaging toward the loose auto
    # boxes. (Pseudo-labels stay in for scene variety.)
    val = manual[:3]; train = pseudo + manual[3:] * 6
    print(f"train {len(train)} (manual up-weighted 6×, val {len(val)} held out), device {DEV}")
    tl = DataLoader(SegSet(train), batch_size=8, shuffle=True)
    net = UNet().to(DEV); opt = torch.optim.Adam(net.parameters(), 1e-3)
    for ep in range(25):
        net.train(); tot = 0
        for x, y in tl:
            x, y = x.to(DEV), y.to(DEV); opt.zero_grad()
            o = net(x); loss = F.binary_cross_entropy_with_logits(o, y) + dice(o, y)
            loss.backward(); opt.step(); tot += loss.item()
        if ep % 5 == 4 or ep == 0:
            net.eval(); ious = []
            with torch.no_grad():
                for s in val:
                    img = np.asarray(Image.open(f"{ROOT}/data/images/{s}.png").convert("L"), np.float32)/255
                    msk = np.asarray(Image.open(f"{ROOT}/data/masks/{s}.png").convert("L"), np.float32)/255
                    H, W = img.shape; ip = np.pad(img, ((0,(-H)%32),(0,(-W)%32)))
                    t = torch.from_numpy(ip)[None,None].to(DEV)
                    p = (torch.sigmoid(net(t))[0,0].cpu().numpy()[:H,:W] > .5)
                    inter = (p & (msk>.5)).sum(); uni = (p | (msk>.5)).sum()
                    ious.append(inter/uni if uni else 0)
            print(f"ep{ep+1:2d} loss {tot/len(tl):.3f} | val mask-IoU {np.mean(ious):.3f}")
    torch.save(net.state_dict(), f"{ROOT}/unet.pt"); print("saved unet.pt")

if __name__ == "__main__":
    main()
