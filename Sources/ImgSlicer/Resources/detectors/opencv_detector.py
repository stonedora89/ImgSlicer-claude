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
                return boxes_from_grid(row_spans, col_spans, scale=scale)
            return boxes_from_spans(col_spans, 0, height, axis="x", scale=scale)

    if height >= width * 1.8:
        row_spans = split_axis_by_separators(gray, axis="y")
        if len(row_spans) > 1:
            if len(row_spans) > 3:
                row_spans = dominant_spans(row_spans, 3)
            col_spans = split_axis_by_separators(gray, axis="x")
            if 1 < len(col_spans) <= 4:
                return boxes_from_grid(row_spans, col_spans, scale=scale)
            return boxes_from_spans(row_spans, 0, width, axis="y", scale=scale)

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
    """Converge onto the true photo edges inside a contact-sheet slot.

    The slot from the equal-width column division and the row band is generous:
    it includes the thin black frame separators on the left/right and the dark
    sprocket / inter-strip gutter above and below. Instead of chopping a fixed
    1/6 off every side (which cut into the photo), we locate the dark gutters
    that bound the photo and snap just inside them.
    """
    height, width = gray.shape[:2]
    col_start = max(0, min(width - 1, col_start))
    col_end = max(col_start + 1, min(width, col_end))
    row_start = max(0, min(height - 1, row_start))
    row_end = max(row_start + 1, min(height, row_end))

    def is_body(section):
        return ((section > 45) & (section < 250)).astype(float)

    # --- Vertical edges: search a window padded past the row band so we can see
    # the dark gutters above and below, then keep the high-content band that
    # contains the slot centre.
    pad_y = max(4, (row_end - row_start) // 3)
    y0 = max(0, row_start - pad_y)
    y1 = min(height, row_end + pad_y)
    centre_y = (row_start + row_end) // 2
    col = gray[y0:y1, col_start:col_end]
    top, bottom = _content_band(is_body(col).mean(axis=1), centre_y - y0, y0)
    if top is None:
        top, bottom = row_start, row_end

    # --- Horizontal edges: within the refined vertical extent, trim the black
    # frame separators on the left/right of the slot.
    pad_x = max(2, (col_end - col_start) // 6)
    x0 = max(0, col_start - pad_x)
    x1 = min(width, col_end + pad_x)
    centre_x = (col_start + col_end) // 2
    rowsec = gray[max(0, top):max(top + 1, bottom), x0:x1]
    left, right = _content_band(is_body(rowsec).mean(axis=0), centre_x - x0, x0)
    if left is None:
        left, right = col_start, col_end

    # Tiny safety inset to stay off the dark border line itself.
    inset_x = max(1, (right - left) // 60)
    inset_y = max(1, (bottom - top) // 60)
    left = min(right - 1, left + inset_x)
    right = max(left + 1, right - inset_x)
    top = min(bottom - 1, top + inset_y)
    bottom = max(top + 1, bottom - inset_y)
    return left, top, right, bottom


def _content_band(profile, centre_index, offset):
    """Return (start, end) absolute bounds of the content band around centre.

    `profile` is a 1-D array of body-content ratios; the band is the run of
    above-threshold samples that contains `centre_index`. Falls back to the
    largest run if the centre sits in a gap.
    """
    n = len(profile)
    if n == 0:
        return None, None
    smoothed = moving_average(profile, max(2, n // 25))
    peak = float(smoothed.max())
    if peak <= 0:
        return None, None
    threshold = max(0.25, peak * 0.5)
    runs = segments(smoothed, threshold, max(2, n // 12), greater=True)
    if not runs:
        return None, None
    centre_index = max(0, min(n - 1, centre_index))
    containing = [r for r in runs if r[0] <= centre_index < r[1]]
    start, end = (containing[0] if containing
                 else max(runs, key=lambda r: r[1] - r[0]))
    return offset + start, offset + end


def split_axis_by_separators(gray, axis):
    height, width = gray.shape[:2]
    if axis == "x":
        dark_profile = (gray <= 62).mean(axis=0)
        edge_profile = np_absdiff(gray, axis=1)
        full = width
    else:
        dark_profile = (gray <= 62).mean(axis=1)
        edge_profile = np_absdiff(gray, axis=0)
        full = height

    edge_max = max(float(edge_profile.max()), 1.0)
    profile = moving_average(dark_profile * 1.9 + (edge_profile / edge_max) * 0.38, max(3, full // 180))
    threshold = max(0.18, min(0.72, float(np_median(profile) + np_std(profile) * 1.35)))
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


def boxes_from_spans(spans, lower, upper, axis, scale):
    boxes = []
    for start, end in spans:
        if axis == "x":
            boxes.append(scaled_box(start, lower, end, upper, scale, confidence=0.78))
        else:
            boxes.append(scaled_box(lower, start, upper, end, scale, confidence=0.78))
    return boxes


def boxes_from_grid(row_spans, col_spans, scale):
    boxes = []
    for top, bottom in row_spans:
        for left, right in col_spans:
            boxes.append(scaled_box(left, top, right, bottom, scale, confidence=0.82))
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
