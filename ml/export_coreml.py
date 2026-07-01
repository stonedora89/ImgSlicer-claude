#!/usr/bin/env python3
"""Convert the trained U-Net to a Core ML package for Swift/Vision inference.

Run after train.py produces unet.pt. Output ml/PhotoSegmenter.mlpackage takes a
grayscale image (H,W multiples of 32) and returns a photo-vs-gutter probability
map; the Swift side thresholds it, extracts connected components, and hands the
boxes to the SAME grid-regularization passes the heuristic detector already uses.

Requires: pip install coremltools
"""
import warnings
warnings.filterwarnings("ignore")
import torch
import coremltools as ct

from train import UNet  # reuse the exact architecture

ROOT = "/Users/howell/work/ImgSlicer-claude/ml"
# A wide contact-sheet shape (multiple of 32). Core ML can take a flexible
# enum of shapes; a single representative size keeps the first cut simple.
H, W = 288, 1024


def main():
    net = UNet()
    net.load_state_dict(torch.load(f"{ROOT}/unet.pt", map_location="cpu"))
    net.eval()

    example = torch.rand(1, 1, H, W)
    traced = torch.jit.trace(net, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 1, H, W))],
        outputs=[ct.TensorType(name="mask_logits")],
        minimum_deployment_target=ct.target.macOS13,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.short_description = "Photo-vs-gutter segmentation for film contact sheets"
    out = f"{ROOT}/PhotoSegmenter.mlpackage"
    mlmodel.save(out)
    print(f"saved {out}")


if __name__ == "__main__":
    main()
