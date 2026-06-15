#!/usr/bin/env python3
import argparse
import json
import sys


def fail(message):
    print(message, file=sys.stderr)
    return 2


def detect_boxes(image_path):
    global np
    try:
        import cv2
        import numpy as np
    except Exception as exc:
        raise RuntimeError(
            "OpenCV detector requires Python packages: opencv-python and numpy"
        ) from exc

    image = cv2.imdecode(np.fromfile(image_path, dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise RuntimeError(f"Unable to open image: {image_path}")

    height, width = image.shape[:2]
    max_side = 1400
    scale = min(1.0, max_side / float(max(width, height)))
    if scale < 1.0:
        work = cv2.resize(image, (max(1, int(width * scale)), max(1, int(height * scale))), interpolation=cv2.INTER_AREA)
    else:
        work = image.copy()

    work_h, work_w = work.shape[:2]
    gray = cv2.cvtColor(work, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)

    structured = detect_structured_layout(gray, scale)
    if len(structured) > 1:
        return structured

    edges = cv2.Canny(gray, 40, 120)
    kernel_size = max(3, int(round(min(work_w, work_h) * 0.006)))
    if kernel_size % 2 == 0:
        kernel_size += 1
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (kernel_size, kernel_size))
    edge_mask = cv2.dilate(edges, kernel, iterations=2)
    edge_mask = cv2.morphologyEx(edge_mask, cv2.MORPH_CLOSE, kernel, iterations=2)

    adaptive = cv2.adaptiveThreshold(
        gray,
        255,
        cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV,
        max(11, kernel_size * 6 + 1),
        4,
    )
    mask = cv2.bitwise_or(edge_mask, adaptive)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=1)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    image_area = float(work_w * work_h)
    boxes = []

    for contour in contours:
        area = cv2.contourArea(contour)
        if area < image_area * 0.002 or area > image_area * 0.86:
            continue

        x, y, w, h = cv2.boundingRect(contour)
        if w < work_w * 0.035 or h < work_h * 0.035:
            continue

        aspect = w / float(max(1, h))
        if aspect < 0.12 or aspect > 8.5:
            continue

        rect_area = float(w * h)
        fill = min(1.0, area / max(1.0, rect_area))
        confidence = max(0.05, min(0.99, fill * 0.65 + min(1.0, rect_area / image_area * 3.0) * 0.35))

        pad_x = max(1, int(round(w * 0.015)))
        pad_y = max(1, int(round(h * 0.015)))
        left = max(0, x - pad_x)
        top = max(0, y - pad_y)
        right = min(work_w, x + w + pad_x)
        bottom = min(work_h, y + h + pad_y)

        boxes.append(
            {
                "left": left / scale,
                "top": top / scale,
                "right": right / scale,
                "bottom": bottom / scale,
                "confidence": confidence,
            }
        )

    boxes = merge_boxes(boxes)
    boxes = sorted(boxes, key=lambda box: (box["top"], box["left"]))
    return boxes


def moving_average(values, window):
    if len(values) == 0:
        return values
    window = max(1, min(int(window), len(values)))
    kernel = np.ones(window, dtype=float) / float(window)
    return np.convolve(values, kernel, mode="same")


def segments(values, threshold, minimum_size, greater):
    result = []
    start = None
    for index, value in enumerate(values):
        matched = value > threshold if greater else value < threshold
        if matched:
            if start is None:
                start = index
        elif start is not None:
            if index - start >= minimum_size:
                result.append((start, index))
            start = None
    if start is not None and len(values) - start >= minimum_size:
        result.append((start, len(values)))
    return result


def merge_segments(items, max_gap):
    if not items:
        return []
    ordered = sorted(items)
    merged = [ordered[0]]
    for start, end in ordered[1:]:
        last_start, last_end = merged[-1]
        if start - last_end <= max_gap:
            merged[-1] = (last_start, max(last_end, end))
        else:
            merged.append((start, end))
    return merged


def select_regular_segments(items, limit):
    if len(items) < limit:
        return []
    ranked = sorted(items, key=lambda item: item[1] - item[0], reverse=True)[:limit]
    selected = sorted(ranked)
    sizes = [end - start for start, end in selected]
    median_size = np_median(sizes)
    if median_size <= 0:
        return []
    for size in sizes:
        ratio = size / float(median_size)
        if ratio < 0.55 or ratio > 1.65:
            return []
    return selected


def np_median(values):
    return float(np.median(np.asarray(values, dtype=float)))


def np_std(values):
    return float(np.std(np.asarray(values, dtype=float)))


def np_absdiff(gray, axis):
    if axis == 1:
        diff = np.zeros(gray.shape[1], dtype=float)
        if gray.shape[1] > 1:
            diff[1:] = np.abs(np.diff(gray.astype(float), axis=1)).mean(axis=0)
        return diff
    diff = np.zeros(gray.shape[0], dtype=float)
    if gray.shape[0] > 1:
        diff[1:] = np.abs(np.diff(gray.astype(float), axis=0)).mean(axis=1)
    return diff


def np_where(mask):
    values = np.where(mask)[0]
    return values.tolist()


def detect_structured_layout(gray, scale):
    height, width = gray.shape[:2]
    if width < 80 or height < 80:
        return []

    contact = detect_contact_sheet(gray, scale)
    if len(contact) >= 20:
        return contact

    if width >= height * 1.8:
        col_spans = split_axis_by_separators(gray, axis="x")
        if len(col_spans) > 1:
            row_spans = split_axis_by_separators(gray, axis="y")
            if len(row_spans) > 2:
                row_spans = dominant_spans(row_spans, 2)
            if 1 < len(row_spans) <= 4:
                return boxes_from_grid(gray, row_spans, col_spans, scale=scale)
            return boxes_from_spans(gray, col_spans, 0, height, axis="x", scale=scale)

    if height >= width * 1.8:
        row_spans = split_axis_by_separators(gray, axis="y")
        if len(row_spans) > 1:
            if len(row_spans) > 3:
                row_spans = dominant_spans(row_spans, 3)
            col_spans = split_axis_by_separators(gray, axis="x")
            if 1 < len(col_spans) <= 4:
                return boxes_from_grid(gray, row_spans, col_spans, scale=scale)
            return boxes_from_spans(gray, row_spans, 0, width, axis="y", scale=scale)

    return []


def detect_contact_sheet(gray, scale):
    height, width = gray.shape[:2]
    if width < 180 or height < 140:
        return []

    main_x_end = max(1, min(width, int(width * 0.90)))
    body = (gray[:, :main_x_end] > 40) & (gray[:, :main_x_end] < 251)
    row_content = body.mean(axis=1)
    row_smoothed = moving_average(row_content, max(3, height // 160))
    threshold = max(0.09, min(0.30, float(np_median(row_smoothed) + np_std(row_smoothed) * 0.35)))
    rows = segments(row_smoothed, threshold, max(12, height // 22), greater=True)
    rows = select_regular_segments(rows, limit=6)
    if len(rows) != 6:
        return []

    main_x_end = max(1, min(width, int(width * 0.755)))
    boxes = []
    for row_start, row_end in rows:
        for index in range(6):
            col_start = int(round(main_x_end * index / 6.0))
            col_end = int(round(main_x_end * (index + 1) / 6.0))
            left, top, right, bottom = refine_contact_cell(
                gray, col_start, col_end, row_start, row_end
            )
            boxes.append(scaled_box(left, top, right, bottom, scale, confidence=0.92))
    return boxes if len(boxes) == 36 else []


def refine_contact_cell(gray, col_start, col_end, row_start, row_end):
    """Contact-sheet slot: pad outward to find the photo/sprocket boundary."""
    return refine_slot(
        gray, col_start, col_end, row_start, row_end,
        pad_x_frac=0.12, pad_y_frac=0.22,
    )


def refine_slot(gray, x0, x1, y0, y1, pad_x_frac=0.12, pad_y_frac=0.12):
    """Converge a candidate slot onto the true photo edges.

    Slots from equal division or separator spans are imperfect in both
    directions: they can include the blank scanner bed / dark gutter (box too
    big) or cut into the photo (box too small). On each axis we locate the
    photo *body* — the contiguous run of mid-tone content — while explicitly
    rejecting the film's sprocket band (bright perforations on a black base),
    so the box neither leaks into the holes nor stops short of the subject. A
    small outward pad lets a subject that spilled past the slot edge be
    recovered.
    """
    height, width = gray.shape[:2]
    x0 = max(0, min(width - 1, int(round(x0))))
    x1 = max(x0 + 1, min(width, int(round(x1))))
    y0 = max(0, min(height - 1, int(round(y0))))
    y1 = max(y0 + 1, min(height, int(round(y1))))

    # --- Vertical edges ---
    pad_y = max(0, int((y1 - y0) * pad_y_frac))
    sy0 = max(0, y0 - pad_y)
    sy1 = min(height, y1 + pad_y)
    band = _photo_band(gray[sy0:sy1, x0:x1], axis="rows", centre=(y0 + y1) // 2 - sy0)
    top, bottom = (sy0 + band[0], sy0 + band[1]) if band else (y0, y1)

    # --- Horizontal edges (within the refined vertical extent) ---
    pad_x = max(0, int((x1 - x0) * pad_x_frac))
    sx0 = max(0, x0 - pad_x)
    sx1 = min(width, x1 + pad_x)
    band = _photo_band(
        gray[max(0, top):max(top + 1, bottom), sx0:sx1],
        axis="cols", centre=(x0 + x1) // 2 - sx0,
    )
    left, right = (sx0 + band[0], sx0 + band[1]) if band else (x0, x1)

    # Tiny safety inset to stay off the dark border line itself.
    inset_x = max(1, (right - left) // 80)
    inset_y = max(1, (bottom - top) // 80)
    left = min(right - 1, left + inset_x)
    right = max(left + 1, right - inset_x)
    top = min(bottom - 1, top + inset_y)
    bottom = max(top + 1, bottom - inset_y)
    return left, top, right, bottom


def _photo_band(section, axis, centre):
    """Bounds (start, end) of the photo body along `axis` within `section`.

    Each line is scored by its mid-tone content minus a sprocket penalty:
    lines that mix bright perforations with a dark film base (the sprocket
    band) score low, so the photo's true edge against that band is found
    instead of the high-contrast hole edges. Returns the above-threshold run
    containing `centre`, or the largest run if the centre sits in a gap.
    """
    if section.size == 0:
        return None
    reduce_axis = 1 if axis == "rows" else 0
    sec = section.astype(float)
    body = ((sec > 45) & (sec < 248)).mean(axis=reduce_axis)
    white = (sec >= 245).mean(axis=reduce_axis)
    dark = (sec <= 40).mean(axis=reduce_axis)
    sprocket = np.where(
        (white >= 0.05) & (dark >= 0.12),
        np.minimum(0.7, white * 1.7 + dark * 0.5),
        0.0,
    )
    score = np.clip(body - sprocket, 0.0, 1.0)
    n = len(score)
    smoothed = moving_average(score, max(2, n // 25))
    peak = float(smoothed.max())
    if peak <= 0:
        return None
    threshold = max(0.30, peak * 0.55)
    runs = segments(smoothed, threshold, max(2, n // 12), greater=True)
    if not runs:
        return None
    centre = max(0, min(n - 1, int(centre)))
    containing = [r for r in runs if r[0] <= centre < r[1]]
    start, end = containing[0] if containing else max(runs, key=lambda r: r[1] - r[0])
    return start, end


def separator_profile(gray, axis):
    """Per-line "separator-ness" in [0, 1] for the given split axis.

    A real gutter between photos is a band that runs across the *whole*
    perpendicular extent and is uniform — either uniformly dark (film
    sprocket gutters, black borders) or uniformly bright (white scanner bed,
    print margins). We score each line by how uniform it is (low variance
    across the perpendicular axis) AND how extreme its tone is, then add a
    small boundary-edge term.

    Keying on uniformity is what separates a true full-width gutter from a
    band of film perforations, whose alternating holes and frame edges make
    the line dark *on average* but highly non-uniform — the old darkness-only
    profile mistook those for separators and over-segmented the layout.
    """
    g = gray.astype(float)
    reduce_axis = 0 if axis == "x" else 1
    line_std = g.std(axis=reduce_axis)
    dark = (gray <= 70).mean(axis=reduce_axis)
    bright = (gray >= 200).mean(axis=reduce_axis)
    edge_profile = np_absdiff(gray, axis=1 if axis == "x" else 0)

    uniform = np.clip((40.0 - line_std) / 40.0, 0.0, 1.0)
    extreme = np.maximum(dark, bright)
    edge_max = max(float(edge_profile.max()), 1.0)
    score = uniform * (0.30 + 0.70 * extreme) + (edge_profile / edge_max) * 0.15
    return np.clip(score, 0.0, 1.0)


def split_axis_by_separators(gray, axis):
    height, width = gray.shape[:2]
    full = width if axis == "x" else height

    profile = moving_average(separator_profile(gray, axis), max(3, full // 180))
    threshold = max(0.22, min(0.80, float(np_median(profile) + np_std(profile) * 1.2)))
    separator_segments = segments(profile, threshold, max(2, full // 420), greater=True)
    separator_segments = merge_segments(separator_segments, max(2, full // 260))

    spans = []
    cursor = 0
    min_span = max(24, full // 18)
    for start, end in separator_segments:
        if start - cursor >= min_span:
            spans.append((cursor, start))
        cursor = max(cursor, end)
    if full - cursor >= min_span:
        spans.append((cursor, full))

    return trim_blank_spans(gray, spans, axis)


def boxes_from_spans(gray, spans, lower, upper, axis, scale):
    boxes = []
    for start, end in spans:
        if axis == "x":
            x0, x1, y0, y1 = start, end, lower, upper
        else:
            x0, x1, y0, y1 = lower, upper, start, end
        left, top, right, bottom = refine_slot(gray, x0, x1, y0, y1)
        boxes.append(scaled_box(left, top, right, bottom, scale, confidence=0.78))
    return boxes


def boxes_from_grid(gray, row_spans, col_spans, scale):
    boxes = []
    for top, bottom in row_spans:
        for left, right in col_spans:
            l, t, r, b = refine_slot(gray, left, right, top, bottom)
            boxes.append(scaled_box(l, t, r, b, scale, confidence=0.82))
    return boxes


def dominant_spans(spans, limit):
    return sorted(sorted(spans, key=lambda span: span[1] - span[0], reverse=True)[:limit])


def trim_blank_spans(gray, spans, axis):
    height, width = gray.shape[:2]
    trimmed = []
    for start, end in spans:
        if axis == "x":
            section = gray[:, start:end]
            if section.size == 0:
                continue
            content = ((section > 35) & (section < 248)).mean(axis=0)
        else:
            section = gray[start:end, :]
            if section.size == 0:
                continue
            content = ((section > 35) & (section < 248)).mean(axis=1)

        hits = np_where(content > 0.035)
        if not hits:
            continue
        left = start + hits[0]
        right = start + hits[-1] + 1
        if right - left >= max(24, (width if axis == "x" else height) // 24):
            trimmed.append((left, right))
    return trimmed


def scaled_box(left, top, right, bottom, scale, confidence):
    return {
        "left": left / scale,
        "top": top / scale,
        "right": right / scale,
        "bottom": bottom / scale,
        "confidence": confidence,
    }


def merge_boxes(boxes):
    merged = []
    for box in boxes:
        current = dict(box)
        changed = True
        while changed:
            changed = False
            for index, other in enumerate(merged):
                if overlap_ratio(current, other) > 0.35 or close_enough(current, other):
                    current = union_box(current, other)
                    del merged[index]
                    changed = True
                    break
        merged.append(current)
    return merged


def overlap_ratio(a, b):
    left = max(a["left"], b["left"])
    top = max(a["top"], b["top"])
    right = min(a["right"], b["right"])
    bottom = min(a["bottom"], b["bottom"])
    intersection = max(0.0, right - left) * max(0.0, bottom - top)
    area_a = max(1.0, (a["right"] - a["left"]) * (a["bottom"] - a["top"]))
    area_b = max(1.0, (b["right"] - b["left"]) * (b["bottom"] - b["top"]))
    return intersection / min(area_a, area_b)


def close_enough(a, b):
    gap_x = max(0.0, max(a["left"], b["left"]) - min(a["right"], b["right"]))
    gap_y = max(0.0, max(a["top"], b["top"]) - min(a["bottom"], b["bottom"]))
    min_side = min(
        a["right"] - a["left"],
        a["bottom"] - a["top"],
        b["right"] - b["left"],
        b["bottom"] - b["top"],
    )
    return gap_x <= min_side * 0.025 and gap_y <= min_side * 0.025


def union_box(a, b):
    confidence = max(a.get("confidence", 0.0), b.get("confidence", 0.0))
    return {
        "left": min(a["left"], b["left"]),
        "top": min(a["top"], b["top"]),
        "right": max(a["right"], b["right"]),
        "bottom": max(a["bottom"], b["bottom"]),
        "confidence": confidence,
    }


def main():
    parser = argparse.ArgumentParser(description="ImgSlicer OpenCV detector")
    parser.add_argument("--detect-json", metavar="IMAGE")
    args = parser.parse_args()

    if not args.detect_json:
        return fail("Usage: opencv_detector.py --detect-json <image-file>")

    try:
        boxes = detect_boxes(args.detect_json)
    except Exception as exc:
        return fail(str(exc))

    print(json.dumps({"boxes": boxes}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
