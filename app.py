from __future__ import annotations

import queue
import threading
import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import numpy as np

try:
    import cv2
except ImportError:
    cv2 = None

try:
    from PIL import Image, ImageDraw, ImageOps, ImageTk
except ImportError as exc:
    raise SystemExit("缺少 Pillow，请先运行: pip install -r requirements.txt") from exc


PREVIEW_SIZE = (980, 680)
SUPPORTED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".webp"}
DARK_THRESHOLD = 55
LIGHT_THRESHOLD = 245
MIN_ROW_RATIO = 0.08
MIN_COL_RATIO = 0.035
SMOOTH_WINDOW_RATIO = 0.01
MERGE_GAP_RATIO = 0.008
BOX_EXPAND_RATIO = 0.0
BOX_EXPAND_MIN = 0
BOX_EXPAND_MAX = 0
CV_MAX_DIMENSION = 1800
CV_BORDER_RATIO = 0.015
CV_MIN_BOX_AREA_RATIO = 0.015
CV_MIN_BOX_DIM_RATIO = 0.12
CV_ROW_ALIGN_RATIO = 0.035
CV_COL_ALIGN_RATIO = 0.035
CV_BLACK_BORDER_THRESHOLD = 70
CV_BORDER_SAMPLE_RATIO = 0.05
CV_DUPLICATE_IOU = 0.82
CV_EDGE_BAND_RATIO = 0.04
SEPARATOR_DARK_RATIO = 0.58
SEPARATOR_MAX_WIDTH_RATIO = 0.012
SEPARATOR_EDGE_RATIO = 0.03
MAX_FRAME_ASPECT_RATIO = 2.35
TARGET_FRAME_ASPECT_RATIO = 1.6
WHITE_TRIM_THRESHOLD = 245
WHITE_TRIM_RATIO = 0.92
WHITE_TRIM_MAX_RATIO = 0.18
BLACK_EDGE_TRIM_THRESHOLD = 65
BLACK_EDGE_TRIM_RATIO = 0.90
BLACK_EDGE_TRIM_MAX_RATIO = 0.08
NEAR_SEPARATOR_MIN_COL_RATIO = 0.055


@dataclass
class Segment:
    start: int
    end: int

    @property
    def size(self) -> int:
        return self.end - self.start


@dataclass
class ProcessResult:
    source_path: Path
    output_dir: Path
    orientation: str
    export_count: int


class DetectionError(Exception):
    pass


def moving_average(values: np.ndarray, window: int) -> np.ndarray:
    if values.size == 0:
        return values
    window = max(1, min(window, values.size))
    kernel = np.ones(window, dtype=np.float32) / window
    return np.convolve(values, kernel, mode="same")


def grayscale_array(image: Image.Image) -> np.ndarray:
    return np.asarray(ImageOps.grayscale(image), dtype=np.uint8)


def normalize_gray_for_detection(gray: np.ndarray) -> np.ndarray:
    if gray.size == 0:
        return gray
    if cv2 is not None:
        min_dim = min(gray.shape[:2])
        bg_kernel = max(31, int(round(min_dim * 0.08)))
        if bg_kernel % 2 == 0:
            bg_kernel += 1
        background = cv2.GaussianBlur(gray, (bg_kernel, bg_kernel), 0)
        corrected = cv2.addWeighted(gray, 1.7, background, -0.7, 32)
        clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 4))
        return clahe.apply(corrected)

    low, high = np.percentile(gray, (2, 98))
    if high <= low:
        return gray.copy()
    stretched = (gray.astype(np.float32) - float(low)) * (255.0 / float(high - low))
    return np.clip(stretched, 0, 255).astype(np.uint8)


def projection_profile_from_array(gray: np.ndarray, axis: str) -> np.ndarray:
    if axis == "x":
        return gray.mean(axis=0, dtype=np.float32)
    return gray.mean(axis=1, dtype=np.float32)


def dark_ratio_profile_from_array(gray: np.ndarray, axis: str, threshold: int = DARK_THRESHOLD) -> np.ndarray:
    mask = gray <= threshold
    if axis == "x":
        return mask.mean(axis=0, dtype=np.float32)
    return mask.mean(axis=1, dtype=np.float32)


def separator_dark_ratio_profile_from_array(gray: np.ndarray, axis: str) -> np.ndarray:
    normalized = normalize_gray_for_detection(gray)
    raw_profile = dark_ratio_profile_from_array(gray, axis, DARK_THRESHOLD)
    normalized_profile = dark_ratio_profile_from_array(normalized, axis, DARK_THRESHOLD)
    return np.minimum(raw_profile, normalized_profile)


def find_segments_by_threshold(values: np.ndarray, threshold: float, minimum_size: int, less_than: bool) -> List[Segment]:
    segments: List[Segment] = []
    matched = values < threshold if less_than else values > threshold
    start = None
    for index, flag in enumerate(matched.tolist()):
        if flag:
            if start is None:
                start = index
        elif start is not None:
            if index - start >= minimum_size:
                segments.append(Segment(start, index))
            start = None
    if start is not None and len(values) - start >= minimum_size:
        segments.append(Segment(start, len(values)))
    return segments


def merge_close_segments(segments: List[Segment], max_gap: int) -> List[Segment]:
    if not segments:
        return []
    ordered = sorted(segments, key=lambda segment: segment.start)
    merged = [ordered[0]]
    for segment in ordered[1:]:
        previous = merged[-1]
        if segment.start - previous.end <= max_gap:
            merged[-1] = Segment(previous.start, max(previous.end, segment.end))
        else:
            merged.append(segment)
    return merged


def detect_orientation(image: Image.Image) -> str:
    return "horizontal" if image.width >= image.height else "vertical"


def normalize_box(size: tuple[int, int], box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    width, height = size
    left, top, right, bottom = box
    return (
        max(0, min(width, left)),
        max(0, min(height, top)),
        max(0, min(width, right)),
        max(0, min(height, bottom)),
    )


def valid_box(box: tuple[int, int, int, int]) -> bool:
    left, top, right, bottom = box
    return right - left > 30 and bottom - top > 30


def expand_box(size: tuple[int, int], box: tuple[int, int, int, int], expand_x: int, expand_y: int) -> tuple[int, int, int, int]:
    left, top, right, bottom = box
    return normalize_box(size, (left - expand_x, top - expand_y, right + expand_x, bottom + expand_y))


def trim_white_edges(gray: np.ndarray, box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    left, top, right, bottom = box
    region = gray[top:bottom, left:right]
    if region.size == 0:
        return box

    height, width = region.shape[:2]
    max_trim_x = max(1, int(width * WHITE_TRIM_MAX_RATIO))
    max_trim_y = max(1, int(height * WHITE_TRIM_MAX_RATIO))
    white_mask = region >= WHITE_TRIM_THRESHOLD
    dark_mask = region <= DARK_THRESHOLD

    col_white = white_mask.mean(axis=0, dtype=np.float32)
    row_white = white_mask.mean(axis=1, dtype=np.float32)
    col_dark = dark_mask.mean(axis=0, dtype=np.float32)
    row_dark = dark_mask.mean(axis=1, dtype=np.float32)

    def leading_trim(white_profile: np.ndarray, dark_profile: np.ndarray, limit: int) -> int:
        amount = 0
        for index in range(min(limit, white_profile.size)):
            if white_profile[index] >= WHITE_TRIM_RATIO and dark_profile[index] <= 0.02:
                amount = index + 1
            else:
                break
        return amount

    def trailing_trim(white_profile: np.ndarray, dark_profile: np.ndarray, limit: int) -> int:
        amount = 0
        for offset in range(1, min(limit, white_profile.size) + 1):
            index = white_profile.size - offset
            if white_profile[index] >= WHITE_TRIM_RATIO and dark_profile[index] <= 0.02:
                amount = offset
            else:
                break
        return amount

    trim_left = leading_trim(col_white, col_dark, max_trim_x)
    trim_right = trailing_trim(col_white, col_dark, max_trim_x)
    trim_top = leading_trim(row_white, row_dark, max_trim_y)
    trim_bottom = trailing_trim(row_white, row_dark, max_trim_y)

    trimmed = (left + trim_left, top + trim_top, right - trim_right, bottom - trim_bottom)
    return trimmed if valid_box(trimmed) else box


def trim_boxes_white_edges(image: Image.Image, boxes: List[tuple[int, int, int, int]]) -> List[tuple[int, int, int, int]]:
    gray = grayscale_array(image)
    trimmed = [trim_white_edges(gray, box) for box in boxes]
    return [box for box in trimmed if valid_box(box)]


def trim_uniform_black_edges(gray: np.ndarray, box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    left, top, right, bottom = box
    region = gray[top:bottom, left:right]
    if region.size == 0:
        return box

    height, width = region.shape[:2]
    max_trim_x = max(1, int(width * BLACK_EDGE_TRIM_MAX_RATIO))
    max_trim_y = max(1, int(height * BLACK_EDGE_TRIM_MAX_RATIO))
    dark_mask = region <= BLACK_EDGE_TRIM_THRESHOLD
    col_dark = dark_mask.mean(axis=0, dtype=np.float32)
    row_dark = dark_mask.mean(axis=1, dtype=np.float32)

    def leading_dark(profile: np.ndarray, limit: int) -> int:
        amount = 0
        for index in range(min(limit, profile.size)):
            if profile[index] >= BLACK_EDGE_TRIM_RATIO:
                amount = index + 1
            else:
                break
        return amount

    def trailing_dark(profile: np.ndarray, limit: int) -> int:
        amount = 0
        for offset in range(1, min(limit, profile.size) + 1):
            index = profile.size - offset
            if profile[index] >= BLACK_EDGE_TRIM_RATIO:
                amount = offset
            else:
                break
        return amount

    trim_left = leading_dark(col_dark, max_trim_x)
    trim_right = trailing_dark(col_dark, max_trim_x)
    trim_top = leading_dark(row_dark, max_trim_y)
    trim_bottom = trailing_dark(row_dark, max_trim_y)

    trimmed = (left + trim_left, top + trim_top, right - trim_right, bottom - trim_bottom)
    return trimmed if valid_box(trimmed) else box


def trim_boxes_black_edges(image: Image.Image, boxes: List[tuple[int, int, int, int]]) -> List[tuple[int, int, int, int]]:
    gray = grayscale_array(image)
    trimmed = [trim_uniform_black_edges(gray, box) for box in boxes]
    return [box for box in trimmed if valid_box(box)]


def detect_rows_from_array(gray: np.ndarray) -> List[Segment]:
    height = gray.shape[0]
    profile = moving_average(projection_profile_from_array(gray, "y"), max(3, int(height * SMOOTH_WINDOW_RATIO)))
    minimum = max(24, int(height * MIN_ROW_RATIO))
    gap = max(6, int(height * MERGE_GAP_RATIO))
    rows = find_segments_by_threshold(profile, LIGHT_THRESHOLD, minimum, less_than=True)
    return merge_close_segments(rows, gap)


def choose_candidate_boundaries(candidates: List[int], width: int) -> List[int]:
    if not candidates:
        return []
    candidates = sorted(set(candidate for candidate in candidates if 0 < candidate < width))
    if len(candidates) <= 1:
        return candidates
    groups: List[List[int]] = [[candidates[0]]]
    for candidate in candidates[1:]:
        if candidate - groups[-1][-1] <= max(4, width // 120):
            groups[-1].append(candidate)
        else:
            groups.append([candidate])
    return [sum(group) // len(group) for group in groups]


def merge_narrow_segments(segments: List[Segment], full_size: int) -> List[Segment]:
    if len(segments) <= 1:
        return segments
    minimum = max(36, int(full_size * 0.09))
    merged = segments[:]
    changed = True
    while changed and len(merged) > 1:
        changed = False
        for index, segment in enumerate(merged):
            if segment.size >= minimum:
                continue
            if index == 0:
                neighbor = merged[1]
                merged[1] = Segment(segment.start, neighbor.end)
                merged.pop(0)
            elif index == len(merged) - 1:
                neighbor = merged[-2]
                merged[-2] = Segment(neighbor.start, segment.end)
                merged.pop()
            else:
                left = merged[index - 1]
                right = merged[index + 1]
                if left.size <= right.size:
                    merged[index - 1] = Segment(left.start, segment.end)
                    merged.pop(index)
                else:
                    merged[index + 1] = Segment(segment.start, right.end)
                    merged.pop(index)
            changed = True
            break
    return merged


def margin_is_blank(gray_region: np.ndarray) -> bool:
    if gray_region.size == 0:
        return True
    mean_value = float(gray_region.mean())
    dark_ratio = float(np.count_nonzero(gray_region <= DARK_THRESHOLD)) / float(gray_region.size)
    return mean_value >= 235.0 and dark_ratio <= 0.03


def protect_outer_column_edges(row_gray: np.ndarray, columns: List[Segment]) -> List[Segment]:
    if not columns:
        return columns
    width = row_gray.shape[1]
    edge_limit = max(48, int(width * 0.04))
    adjusted = columns[:]

    first = adjusted[0]
    if first.start > edge_limit and not margin_is_blank(row_gray[:, :first.start]):
        adjusted[0] = Segment(0, first.end)

    last = adjusted[-1]
    if width - last.end > edge_limit and not margin_is_blank(row_gray[:, last.end:]):
        adjusted[-1] = Segment(last.start, width)

    return adjusted


def trim_outer_blank_column_edges(row_gray: np.ndarray, columns: List[Segment]) -> List[Segment]:
    if not columns:
        return columns
    height, width = row_gray.shape[:2]
    if height == 0 or width == 0:
        return columns

    white_mask = row_gray >= WHITE_TRIM_THRESHOLD
    dark_mask = row_gray <= DARK_THRESHOLD
    white_profile = white_mask.mean(axis=0, dtype=np.float32)
    dark_profile = dark_mask.mean(axis=0, dtype=np.float32)
    scan_limit = max(1, int(width * 0.25))

    left_bound = 0
    for index in range(min(scan_limit, width)):
        if white_profile[index] >= 0.97 and dark_profile[index] <= 0.01:
            left_bound = index + 1
        else:
            break

    right_bound = width
    for offset in range(1, min(scan_limit, width) + 1):
        index = width - offset
        if white_profile[index] >= 0.97 and dark_profile[index] <= 0.01:
            right_bound = index
        else:
            break

    if left_bound >= right_bound:
        return columns

    trimmed: List[Segment] = []
    for column in columns:
        start = max(column.start, left_bound)
        end = min(column.end, right_bound)
        if end - start >= max(24, int(width * MIN_COL_RATIO)):
            trimmed.append(Segment(start, end))
    return trimmed if trimmed else columns


def segments_between_dark_separators(row_gray: np.ndarray) -> List[Segment]:
    width = row_gray.shape[1]
    smooth = max(3, int(width * SMOOTH_WINDOW_RATIO))
    dark_profile = moving_average(separator_dark_ratio_profile_from_array(row_gray, "x"), smooth)
    if dark_profile.size == 0:
        return []

    continuous_profile = continuous_dark_separator_profile(row_gray)
    median_dark = float(np.median(dark_profile))
    max_dark = float(np.max(dark_profile))
    threshold = max(SEPARATOR_DARK_RATIO, median_dark + (max_dark - median_dark) * 0.45)
    min_band_width = max(2, width // 600)
    merge_gap = max(2, width // 220)
    max_band_width = max(24, int(width * SEPARATOR_MAX_WIDTH_RATIO))
    loose_band_width = max(max_band_width * 3, int(width * 0.06))
    edge_limit = max(16, int(width * SEPARATOR_EDGE_RATIO))
    minimum_column = max(24, int(width * MIN_COL_RATIO))

    bands = merge_close_segments(
        find_segments_by_threshold(dark_profile, threshold, min_band_width, less_than=False),
        merge_gap,
    )
    bands = [
        clamp_separator_band(band, continuous_profile, max_band_width)
        for band in bands
        if band.size <= loose_band_width and separator_band_is_continuous(continuous_profile, band)
    ]
    bands = coalesce_near_separator_bands(bands, width)
    if not bands:
        return []

    start = 0
    end = width
    interior: List[Segment] = []
    for band in bands:
        if band.end <= edge_limit:
            start = max(start, band.start)
        elif band.start >= width - edge_limit:
            end = min(end, band.end)
        else:
            interior.append(band)

    if start >= end:
        return []

    columns: List[Segment] = []
    cursor = start
    for band in interior:
        if band.start - cursor >= minimum_column:
            columns.append(Segment(cursor, band.start))
        cursor = max(cursor, band.end)
    if end - cursor >= minimum_column:
        columns.append(Segment(cursor, end))

    if len(columns) >= 2:
        columns = protect_outer_column_edges(row_gray, merge_narrow_segments(columns, width))
        return columns
    return []


def continuous_dark_separator_profile(row_gray: np.ndarray) -> np.ndarray:
    height, width = row_gray.shape[:2]
    if height == 0 or width == 0:
        return np.zeros(width, dtype=np.float32)
    slice_count = 5 if height >= 80 else 3
    profiles: List[np.ndarray] = []
    smooth = max(3, int(width * SMOOTH_WINDOW_RATIO))
    for index in range(slice_count):
        start = int(round(height * index / slice_count))
        end = int(round(height * (index + 1) / slice_count))
        if end <= start:
            continue
        profile = separator_dark_ratio_profile_from_array(row_gray[start:end, :], "x")
        profiles.append(moving_average(profile, smooth))
    if not profiles:
        return np.zeros(width, dtype=np.float32)
    return np.minimum.reduce(profiles)


def coalesce_near_separator_bands(bands: List[Segment], width: int) -> List[Segment]:
    if len(bands) <= 1:
        return bands
    min_photo_width = max(24, int(width * NEAR_SEPARATOR_MIN_COL_RATIO))
    ordered = sorted(bands, key=lambda band: band.start)
    result: List[Segment] = []
    group: List[Segment] = [ordered[0]]
    for band in ordered[1:]:
        previous = group[-1]
        if band.start - previous.end < min_photo_width:
            group.append(band)
            continue
        result.append(group[0])
        group = [band]
    result.append(group[0])
    return result


def separator_band_is_continuous(profile: np.ndarray, band: Segment) -> bool:
    if profile.size == 0 or band.end <= band.start:
        return False
    sample = profile[max(0, band.start):min(profile.size, band.end)]
    if sample.size == 0:
        return False
    return float(sample.max()) >= 0.42 and float(sample.mean()) >= 0.24


def clamp_separator_band(band: Segment, profile: np.ndarray, max_width: int) -> Segment:
    if band.size <= max_width:
        return band
    start = max(0, band.start)
    end = min(profile.size, band.end)
    sample = profile[start:end]
    if sample.size == 0:
        return Segment(band.start, min(band.end, band.start + max_width))
    threshold = max(0.42, float(sample.max()) * 0.80)
    core_candidates = merge_close_segments(
        find_segments_by_threshold(sample, threshold, max(2, max_width // 12), less_than=False),
        max(2, max_width // 20),
    )
    if core_candidates:
        core = core_candidates[0]
        core_start = start + core.start
        return Segment(core_start, min(band.end, core_start + max_width))
    return Segment(band.start, min(band.end, band.start + max_width))


def split_wide_columns_by_local_edges(
    row_gray: np.ndarray,
    columns: List[Segment],
    target_width: float | None = None,
) -> List[Segment]:
    if not columns:
        return columns
    height, width = row_gray.shape[:2]
    if height <= 0 or width <= 0:
        return columns

    minimum = max(24, int(width * MIN_COL_RATIO))
    if target_width is None:
        normal_widths = [column.size for column in columns if column.size / max(1, height) <= MAX_FRAME_ASPECT_RATIO]
        if normal_widths:
            target_width = float(np.median(np.asarray(normal_widths, dtype=np.float32)))
        else:
            target_width = float(height * TARGET_FRAME_ASPECT_RATIO)
    if target_width < minimum:
        return columns

    dark_profile = moving_average(separator_dark_ratio_profile_from_array(row_gray, "x"), max(3, int(width * SMOOTH_WINDOW_RATIO)))
    gray_float = row_gray.astype(np.float32)
    if width > 1:
        edge_profile = np.zeros(width, dtype=np.float32)
        edge_profile[1:] = np.mean(np.abs(np.diff(gray_float, axis=1)), axis=0)
        edge_profile = moving_average(edge_profile, max(3, int(width * SMOOTH_WINDOW_RATIO)))
        edge_max = float(edge_profile.max()) if edge_profile.size else 0.0
        if edge_max > 0:
            edge_profile = edge_profile / edge_max
    else:
        edge_profile = np.zeros(width, dtype=np.float32)
    score = dark_profile * 2.0 + edge_profile * 0.75

    balanced: List[Segment] = []
    for column in columns:
        if column.size <= target_width * 1.85:
            balanced.append(column)
            continue

        parts = int(round(column.size / target_width))
        max_parts = max(2, column.size // minimum)
        parts = max(2, min(parts, max_parts))
        if parts <= 1:
            balanced.append(column)
            continue

        search_radius = max(8, int(round(target_width * 0.18)))
        split_points: List[int] = []
        for part in range(1, parts):
            ideal = int(round(column.start + column.size * part / parts))
            left = max(column.start + minimum, ideal - search_radius)
            right = min(column.end - minimum, ideal + search_radius)
            if right <= left:
                split_points.append(ideal)
                continue
            local = score[left:right]
            offset = int(np.argmax(local)) if local.size else 0
            split_points.append(left + offset)

        points = [column.start] + choose_candidate_boundaries(split_points, width) + [column.end]
        for start, end in zip(points, points[1:]):
            if end - start >= minimum:
                balanced.append(Segment(start, end))

    return balanced


def overlap_size(a: Segment, b: Segment) -> int:
    return max(0, min(a.end, b.end) - max(a.start, b.start))


def segment_center(segment: Segment) -> int:
    return (segment.start + segment.end) // 2


def choose_reference_columns(row_columns: List[List[Segment]]) -> List[Segment]:
    candidates = [columns for columns in row_columns if len(columns) >= 2]
    if not candidates:
        return []
    return max(
        candidates,
        key=lambda columns: (
            len(columns),
            -float(np.std(np.asarray([column.size for column in columns], dtype=np.float32))),
        ),
    )


def split_columns_by_reference(columns: List[Segment], reference: List[Segment], width: int) -> List[Segment]:
    if not reference:
        return columns
    if not columns:
        return reference[:]
    if len(columns) == len(reference):
        typical_width = float(np.median(np.asarray([column.size for column in reference], dtype=np.float32)))
        adjusted: List[Segment] = []
        changed = False
        for column, ref in zip(columns, reference):
            if column.size < typical_width * 0.86 and ref.size >= typical_width * 0.86:
                adjusted.append(Segment(ref.start, ref.end))
                changed = True
            else:
                adjusted.append(column)
        return adjusted if changed else columns
    if len(columns) >= len(reference):
        return columns

    min_overlap = max(24, int(width * 0.012))
    typical_width = float(np.median(np.asarray([column.size for column in reference], dtype=np.float32)))
    adjusted: List[Segment] = []
    changed = False

    for column in columns:
        matches = [
            ref
            for ref in reference
            if overlap_size(column, ref) >= min_overlap or column.start <= segment_center(ref) <= column.end
        ]
        if len(matches) >= 2 and column.size >= typical_width * 1.25:
            adjusted.extend(matches)
            changed = True
        else:
            adjusted.append(column)

    if not changed:
        return columns

    return merge_narrow_segments(sorted(adjusted, key=lambda segment: segment.start), width)


def force_columns_from_layout(row_gray: np.ndarray, columns: List[Segment], reference: List[Segment]) -> List[Segment]:
    width = row_gray.shape[1]
    if width <= 0:
        return columns

    target_width = None
    if reference:
        target_width = float(np.median(np.asarray([column.size for column in reference], dtype=np.float32)))
        columns = split_columns_by_reference(columns, reference, width)

    if not columns and target_width:
        count = max(1, int(round(width / target_width)))
        if count >= 2:
            points = [int(round(width * index / count)) for index in range(count + 1)]
            columns = [Segment(start, end) for start, end in zip(points, points[1:]) if end - start >= max(24, int(width * MIN_COL_RATIO))]

    if columns:
        columns = split_wide_columns_by_local_edges(row_gray, columns, target_width)

    return columns


def separator_is_black(gray: np.ndarray, box_a: tuple[int, int, int, int], box_b: tuple[int, int, int, int]) -> bool:
    left_a, top_a, right_a, bottom_a = box_a
    left_b, top_b, right_b, bottom_b = box_b
    height, width = gray.shape[:2]
    band = max(6, int(round(min(width, height) * 0.006)))

    horizontal_overlap = min(right_a, right_b) - max(left_a, left_b)

    if horizontal_overlap > min(right_a - left_a, right_b - left_b) * 0.70:
        center = (bottom_a + top_b) // 2
        left = max(left_a, left_b)
        right = min(right_a, right_b)
        region = gray[max(0, center - band):min(height, center + band), left:right]
    else:
        return True

    if region.size == 0:
        return True
    mean_value = float(region.mean())
    very_dark_ratio = float(np.count_nonzero(region <= 55)) / float(region.size)
    return mean_value <= 38.0 and very_dark_ratio >= 0.82


def merge_false_splits(image: Image.Image, boxes: List[tuple[int, int, int, int]]) -> List[tuple[int, int, int, int]]:
    if len(boxes) <= 1:
        return boxes
    gray = grayscale_array(image)
    merged = order_boxes(boxes, image.size)
    changed = True
    while changed:
        changed = False
        result: List[tuple[int, int, int, int]] = []
        index = 0
        while index < len(merged):
            current = merged[index]
            if index + 1 < len(merged):
                next_box = merged[index + 1]
                if not separator_is_black(gray, current, next_box):
                    current = (
                        min(current[0], next_box[0]),
                        min(current[1], next_box[1]),
                        max(current[2], next_box[2]),
                        max(current[3], next_box[3]),
                    )
                    changed = True
                    index += 2
                    result.append(current)
                    continue
            result.append(current)
            index += 1
        merged = order_boxes(result, image.size)
    return merged


def pil_to_bgr_array(image: Image.Image) -> np.ndarray:
    return cv2.cvtColor(np.asarray(image.convert("RGB")), cv2.COLOR_RGB2BGR)


def resize_for_cv(image_bgr: np.ndarray) -> tuple[np.ndarray, float]:
    height, width = image_bgr.shape[:2]
    longest = max(height, width)
    if longest <= CV_MAX_DIMENSION:
        return image_bgr, 1.0
    scale = CV_MAX_DIMENSION / float(longest)
    resized = cv2.resize(image_bgr, (int(width * scale), int(height * scale)), interpolation=cv2.INTER_AREA)
    return resized, scale


def box_area(box: tuple[int, int, int, int]) -> int:
    left, top, right, bottom = box
    return max(0, right - left) * max(0, bottom - top)


def box_iou(box_a: tuple[int, int, int, int], box_b: tuple[int, int, int, int]) -> float:
    left = max(box_a[0], box_b[0])
    top = max(box_a[1], box_b[1])
    right = min(box_a[2], box_b[2])
    bottom = min(box_a[3], box_b[3])
    intersection = box_area((left, top, right, bottom))
    if intersection <= 0:
        return 0.0
    union = box_area(box_a) + box_area(box_b) - intersection
    return intersection / union if union else 0.0


def border_edge_strength(gray: np.ndarray, box: tuple[int, int, int, int]) -> float:
    left, top, right, bottom = box
    region = gray[top:bottom, left:right]
    if region.size == 0:
        return 0.0
    height, width = region.shape[:2]
    band = max(2, int(round(min(width, height) * CV_EDGE_BAND_RATIO)))
    grad_x = cv2.Sobel(region, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(region, cv2.CV_32F, 0, 1, ksize=3)
    gx = np.abs(grad_x)
    gy = np.abs(grad_y)
    top_band = gy[:band, :]
    bottom_band = gy[max(0, height - band):, :]
    left_band = gx[:, :band]
    right_band = gx[:, max(0, width - band):]
    samples = [sample for sample in (top_band, bottom_band, left_band, right_band) if sample.size > 0]
    if not samples:
        return 0.0
    edge_mean = float(np.mean([float(sample.mean()) for sample in samples]))
    return min(1.0, edge_mean / 64.0)


def candidate_score(gray: np.ndarray, box: tuple[int, int, int, int], extent: float, rectangularity: float, vertex_score: float) -> float:
    dark_score = border_dark_ratio(gray, box)
    edge_score = border_edge_strength(gray, box)
    return dark_score * 0.40 + edge_score * 0.30 + extent * 0.15 + rectangularity * 0.10 + vertex_score * 0.05


def border_dark_ratio(gray: np.ndarray, box: tuple[int, int, int, int]) -> float:
    left, top, right, bottom = box
    width = right - left
    height = bottom - top
    sample = max(2, int(round(min(width, height) * CV_BORDER_SAMPLE_RATIO)))
    top_band = gray[top:min(bottom, top + sample), left:right]
    bottom_band = gray[max(top, bottom - sample):bottom, left:right]
    left_band = gray[top:bottom, left:min(right, left + sample)]
    right_band = gray[top:bottom, max(left, right - sample):right]
    bands = [band for band in (top_band, bottom_band, left_band, right_band) if band.size > 0]
    if not bands:
        return 0.0
    dark_pixels = sum(np.count_nonzero(band <= CV_BLACK_BORDER_THRESHOLD) for band in bands)
    total_pixels = sum(int(band.size) for band in bands)
    return dark_pixels / total_pixels if total_pixels else 0.0


def deduplicate_boxes(boxes: List[tuple[int, int, int, int]], scores: List[float]) -> List[tuple[int, int, int, int]]:
    kept: List[tuple[tuple[int, int, int, int], float]] = []
    for box, score in sorted(zip(boxes, scores), key=lambda item: item[1], reverse=True):
        if any(box_iou(box, existing_box) >= CV_DUPLICATE_IOU for existing_box, _ in kept):
            continue
        kept.append((box, score))
    return [box for box, _ in kept]


def order_boxes(boxes: List[tuple[int, int, int, int]], image_size: tuple[int, int]) -> List[tuple[int, int, int, int]]:
    if len(boxes) <= 1:
        return boxes
    width, height = image_size
    row_threshold = max(12, int(height * CV_ROW_ALIGN_RATIO))
    ordered = sorted(boxes, key=lambda box: (box[1], box[0]))
    rows: List[List[tuple[int, int, int, int]]] = []
    for box in ordered:
        if not rows or abs(box[1] - rows[-1][0][1]) > row_threshold:
            rows.append([box])
        else:
            rows[-1].append(box)
    result: List[tuple[int, int, int, int]] = []
    for row in rows:
        result.extend(sorted(row, key=lambda box: box[0]))
    return result


def detect_photo_boxes_cv(image: Image.Image) -> List[tuple[int, int, int, int]]:
    if cv2 is None:
        raise DetectionError("OpenCV ???")

    image_bgr = pil_to_bgr_array(image)
    resized, scale = resize_for_cv(image_bgr)
    gray = cv2.cvtColor(resized, cv2.COLOR_BGR2GRAY)

    denoised = cv2.bilateralFilter(gray, d=9, sigmaColor=75, sigmaSpace=75)
    min_dim = min(resized.shape[:2])
    bg_kernel = max(31, int(round(min_dim * 0.05)))
    if bg_kernel % 2 == 0:
        bg_kernel += 1
    background = cv2.medianBlur(denoised, bg_kernel)
    corrected = cv2.normalize(cv2.subtract(denoised, background), None, 0, 255, cv2.NORM_MINMAX)

    clahe = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8))
    normalized = clahe.apply(corrected)

    grad_x = cv2.Sobel(normalized, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(normalized, cv2.CV_32F, 0, 1, ksize=3)
    gradient = cv2.convertScaleAbs(cv2.addWeighted(cv2.convertScaleAbs(grad_x), 0.5, cv2.convertScaleAbs(grad_y), 0.5, 0))

    otsu_high, _ = cv2.threshold(gradient, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    high = max(25, int(otsu_high))
    low = max(8, int(high * 0.35))
    edges_canny = cv2.Canny(normalized, low, high, L2gradient=True)

    block = max(11, int(round(min_dim * 0.03)))
    if block % 2 == 0:
        block += 1
    try:
        edges_adaptive = cv2.adaptiveThreshold(normalized, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, block, 8)
    except Exception:
        edges_adaptive = cv2.threshold(normalized, high, 255, cv2.THRESH_BINARY_INV)[1]

    edges = cv2.bitwise_or(edges_canny, edges_adaptive)

    kernel = max(3, int(round(min_dim * 0.012)))
    if kernel % 2 == 0:
        kernel += 1
    close_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (kernel, kernel))
    vertical_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (3, max(5, kernel * 2 + 1)))
    horizontal_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(5, kernel * 2 + 1), 3))
    mask = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, close_kernel, iterations=2)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, vertical_kernel, iterations=1)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, horizontal_kernel, iterations=1)

    contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
    min_area = resized.shape[0] * resized.shape[1] * CV_MIN_BOX_AREA_RATIO
    min_width = resized.shape[1] * CV_MIN_BOX_DIM_RATIO
    min_height = resized.shape[0] * CV_MIN_BOX_DIM_RATIO
    pad = max(6, int(round(min(resized.shape[:2]) * CV_BORDER_RATIO)))

    raw_boxes: List[tuple[int, int, int, int]] = []
    for contour in contours:
        perimeter = cv2.arcLength(contour, True)
        if perimeter <= 0:
            continue
        polygon = cv2.approxPolyDP(contour, 0.02 * perimeter, True)
        x, y, w, h = cv2.boundingRect(polygon if len(polygon) >= 4 else contour)
        area = float(w * h)
        if area < min_area or w < min_width or h < min_height:
            continue

        contour_area = cv2.contourArea(contour)
        extent = contour_area / area if area else 0.0
        rectangularity = contour_area / float(w * h) if w and h else 0.0
        vertex_score = 1.0 if len(polygon) == 4 else max(0.45, 1.0 - abs(len(polygon) - 4) * 0.12)

        candidate = normalize_box((resized.shape[1], resized.shape[0]), (x - pad, y - pad, x + w + pad, y + h + pad))
        if not valid_box(candidate):
            continue

        score = candidate_score(normalized, candidate, extent, rectangularity, vertex_score)
        if score < 0.45:
            continue
        raw_boxes.append(candidate)

    if not raw_boxes:
        raise DetectionError("OpenCV ????????")

    rescored_boxes: List[tuple[tuple[int, int, int, int], float]] = []
    for box in raw_boxes:
        left, top, right, bottom = box
        region = mask[top:bottom, left:right]
        region_area = max(1, (right - left) * (bottom - top))
        extent = float(np.count_nonzero(region)) / float(region_area)
        rectangularity = extent
        vertex_score = 1.0
        score = candidate_score(normalized, box, extent, rectangularity, vertex_score)
        rescored_boxes.append((box, score))

    rescored_boxes.sort(key=lambda item: item[1], reverse=True)
    boxes = deduplicate_boxes([box for box, _ in rescored_boxes], [score for _, score in rescored_boxes])

    if not boxes:
        raise DetectionError("OpenCV ????????")

    if scale != 1.0:
        restored: List[tuple[int, int, int, int]] = []
        for left, top, right, bottom in boxes:
            restored.append(
                normalize_box(
                    image.size,
                    (
                        int(round(left / scale)),
                        int(round(top / scale)),
                        int(round(right / scale)),
                        int(round(bottom / scale)),
                    ),
                )
            )
        boxes = restored

    return order_boxes(boxes, image.size)


def detect_columns_in_row_from_array(row_gray: np.ndarray) -> List[Segment]:
    separator_columns = segments_between_dark_separators(row_gray)
    if separator_columns:
        return separator_columns
    return []


def detect_photo_boxes_legacy(image: Image.Image, orientation: str) -> List[tuple[int, int, int, int]]:
    if orientation == "vertical":
        rotated = image.transpose(Image.Transpose.ROTATE_90)
        rotated_boxes = detect_photo_boxes_legacy(rotated, "horizontal")
        boxes = []
        for left, top, right, bottom in rotated_boxes:
            new_left = image.width - bottom
            new_top = left
            new_right = image.width - top
            new_bottom = right
            boxes.append(normalize_box(image.size, (new_left, new_top, new_right, new_bottom)))
        return merge_false_splits(image, boxes)

    gray = grayscale_array(image)
    rows = detect_rows_from_array(gray)
    if not rows:
        raise DetectionError("???????")

    boxes: List[tuple[int, int, int, int]] = []
    expand_x = min(BOX_EXPAND_MAX, max(BOX_EXPAND_MIN, int(image.width * BOX_EXPAND_RATIO)))
    expand_y = min(BOX_EXPAND_MAX, max(BOX_EXPAND_MIN, int(image.height * BOX_EXPAND_RATIO)))

    row_columns: List[List[Segment]] = []
    for row in rows:
        row_gray = gray[row.start:row.end, :]
        row_columns.append(detect_columns_in_row_from_array(row_gray))

    reference_columns = choose_reference_columns(row_columns)

    for row, detected_columns in zip(rows, row_columns):
        row_gray = gray[row.start:row.end, :]
        columns = force_columns_from_layout(row_gray, detected_columns, reference_columns)
        columns = trim_outer_blank_column_edges(row_gray, columns)
        if not columns:
            box = expand_box(image.size, (0, row.start, image.width, row.end), 0, expand_y)
            if valid_box(box):
                boxes.append(box)
            continue
        for column in columns:
            box = expand_box(
                image.size,
                (column.start, row.start, column.end, row.end),
                expand_x,
                expand_y,
            )
            if valid_box(box):
                boxes.append(box)

    if not boxes:
        raise DetectionError("??????????")
    return merge_false_splits(image, boxes)



def detect_photo_boxes(image: Image.Image, orientation: str) -> List[tuple[int, int, int, int]]:
    try:
        boxes = detect_photo_boxes_legacy(image, orientation)
        if boxes:
            boxes = order_boxes(boxes, image.size)
            return order_boxes(trim_boxes_black_edges(image, boxes), image.size)
    except DetectionError as legacy_error:
        last_error = legacy_error

    if cv2 is not None:
        try:
            boxes = detect_photo_boxes_cv(image)
            if boxes:
                boxes = order_boxes(boxes, image.size)
                return order_boxes(trim_boxes_black_edges(image, boxes), image.size)
        except DetectionError as cv_error:
            last_error = cv_error
            pass

    raise last_error if "last_error" in locals() else DetectionError("未能识别出可切分照片")


def list_image_files(folder_path: Path) -> List[Path]:
    return sorted(path for path in folder_path.iterdir() if path.is_file() and path.suffix.lower() in SUPPORTED_EXTENSIONS)


def export_crops(source_path: Path) -> ProcessResult:
    output_dir = source_path.parent / f"{source_path.stem}_split"
    output_dir.mkdir(exist_ok=True)

    for old_file in output_dir.glob(f"{source_path.stem}-*.jpg"):
        old_file.unlink(missing_ok=True)

    with Image.open(source_path) as image_file:
        image = image_file.convert("RGB")
        orientation = detect_orientation(image)
        boxes = detect_photo_boxes(image, orientation)

        for index, box in enumerate(boxes, start=1):
            cropped = image.crop(box)
            output_path = output_dir / f"{source_path.stem}-{index}.jpg"
            cropped.save(output_path, quality=95)

    return ProcessResult(source_path=source_path, output_dir=output_dir, orientation=orientation, export_count=len(boxes))


def build_preview(image_path: Path) -> tuple[Image.Image, List[tuple[int, int, int, int]], str]:
    with Image.open(image_path) as image_file:
        image = image_file.convert("RGB")
        orientation = detect_orientation(image)
        boxes = detect_photo_boxes(image, orientation)
        preview = image.copy()
    return preview, boxes, orientation


class FilmSplitterApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("胶片扫描批量切分工具")
        self.root.geometry("1320x860")

        self.folder_path: Path | None = None
        self.image_files: List[Path] = []
        self.preview_image_path: Path | None = None
        self.preview_source_image: Image.Image | None = None
        self.preview_boxes: List[tuple[int, int, int, int]] = []
        self.preview_photo: ImageTk.PhotoImage | None = None
        self.preview_scale = 1.0
        self.preview_offset = (0, 0)
        self.selected_box_index: int | None = None
        self.drag_mode: str | None = None
        self.drag_start_canvas = (0, 0)
        self.drag_origin_box: tuple[int, int, int, int] | None = None
        self.is_processing = False
        self.worker_thread: threading.Thread | None = None
        self.event_queue: queue.Queue = queue.Queue()

        self.progress_var = tk.DoubleVar(value=0.0)
        self.folder_var = tk.StringVar(value="请选择扫描文件夹")
        self.status_var = tk.StringVar(value="等待开始")
        self.preview_info_var = tk.StringVar(value="未加载预览")
        self.box_info_var = tk.StringVar(value="未选择照片")

        self._build_ui()

    def _build_ui(self) -> None:
        controls = ttk.Frame(self.root, padding=12)
        controls.pack(side=tk.TOP, fill=tk.X)

        ttk.Button(controls, text="选择文件夹", command=self.choose_folder).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(controls, text="预览首张", command=self.preview_first_image).pack(side=tk.LEFT, padx=8)
        ttk.Button(controls, text="开始批量切分", command=self.start_batch_process).pack(side=tk.LEFT, padx=8)
        ttk.Label(controls, textvariable=self.status_var).pack(side=tk.RIGHT)

        folder_bar = ttk.Frame(self.root, padding=(12, 0, 12, 8))
        folder_bar.pack(side=tk.TOP, fill=tk.X)
        ttk.Label(folder_bar, text="文件夹:").pack(side=tk.LEFT)
        ttk.Label(folder_bar, textvariable=self.folder_var).pack(side=tk.LEFT, padx=(8, 0))

        progress_bar_frame = ttk.Frame(self.root, padding=(12, 0, 12, 8))
        progress_bar_frame.pack(side=tk.TOP, fill=tk.X)
        self.progress_bar = ttk.Progressbar(progress_bar_frame, maximum=100, variable=self.progress_var)
        self.progress_bar.pack(fill=tk.X)

        preview_bar = ttk.Frame(self.root, padding=(12, 0, 12, 8))
        preview_bar.pack(side=tk.TOP, fill=tk.X)
        ttk.Label(preview_bar, textvariable=self.preview_info_var).pack(side=tk.LEFT)
        ttk.Label(preview_bar, text=" | ").pack(side=tk.LEFT)
        ttk.Label(preview_bar, textvariable=self.box_info_var).pack(side=tk.LEFT)

        image_bar = ttk.Frame(self.root, padding=(12, 0, 12, 8))
        image_bar.pack(side=tk.TOP, fill=tk.X)
        ttk.Button(image_bar, text="选择单张照片预览", command=self.choose_preview_image).pack(side=tk.LEFT, padx=(0, 8))
        ttk.Button(image_bar, text="上一个", command=self.preview_previous_image).pack(side=tk.LEFT, padx=4)
        ttk.Button(image_bar, text="下一个", command=self.preview_next_image).pack(side=tk.LEFT, padx=4)
        ttk.Button(image_bar, text="重新识别", command=self.redetect_current_preview).pack(side=tk.LEFT, padx=4)

        self.canvas = tk.Canvas(self.root, bg="#202020", highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True, padx=12, pady=(0, 12))
        self.canvas.bind("<Button-1>", self.on_canvas_press)
        self.canvas.bind("<B1-Motion>", self.on_canvas_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_canvas_release)
        self.canvas.bind("<Configure>", self.on_canvas_resize)

    def choose_folder(self) -> None:
        folder = filedialog.askdirectory(title="选择扫描图片文件夹")
        if not folder:
            return
        self.folder_path = Path(folder)
        self.image_files = list_image_files(self.folder_path)
        self.folder_var.set(str(self.folder_path))
        self.progress_var.set(0)
        self.preview_image_path = None
        self.preview_source_image = None
        self.preview_boxes = []
        self.selected_box_index = None
        self.canvas.delete("all")

        if not self.image_files:
            self.status_var.set("该文件夹没有可处理图片")
            self.preview_info_var.set("未找到支持的图片格式")
            messagebox.showwarning("提示", "该文件夹内没有支持的图片文件")
            return

        self.status_var.set(f"共找到 {len(self.image_files)} 张扫描图")
        self.preview_info_var.set("可先点击预览首张，确认切分效果")
        self.box_info_var.set("未选择照片")

    def choose_preview_image(self) -> None:
        file_path = filedialog.askopenfilename(
            title="选择一张扫描图预览",
            filetypes=[("图片文件", "*.jpg *.jpeg *.png *.tif *.tiff *.bmp *.webp")],
            initialdir=str(self.folder_path) if self.folder_path else None,
        )
        if not file_path:
            return
        path = Path(file_path)
        if self.folder_path and path.parent == self.folder_path and path not in self.image_files:
            self.image_files.append(path)
            self.image_files = sorted(self.image_files)
        self.load_preview_image(path)

    def preview_first_image(self) -> None:
        if not self.image_files:
            messagebox.showwarning("提示", "请先选择包含扫描图的文件夹")
            return
        self.load_preview_image(self.image_files[0])

    def preview_previous_image(self) -> None:
        if not self.image_files or self.preview_image_path not in self.image_files:
            return
        index = self.image_files.index(self.preview_image_path)
        self.load_preview_image(self.image_files[(index - 1) % len(self.image_files)])

    def preview_next_image(self) -> None:
        if not self.image_files or self.preview_image_path not in self.image_files:
            return
        index = self.image_files.index(self.preview_image_path)
        self.load_preview_image(self.image_files[(index + 1) % len(self.image_files)])

    def redetect_current_preview(self) -> None:
        if not self.preview_image_path:
            messagebox.showwarning("提示", "请先加载一张预览图片")
            return
        self.load_preview_image(self.preview_image_path)

    def load_preview_image(self, image_path: Path) -> None:
        self.preview_image_path = image_path
        try:
            preview, boxes, orientation = build_preview(self.preview_image_path)
        except Exception as exc:
            messagebox.showerror("预览失败", f"{self.preview_image_path.name}\n{exc}")
            return
        self.preview_source_image = preview
        self.preview_boxes = boxes
        self.selected_box_index = 0 if boxes else None
        self.preview_info_var.set(
            f"预览: {self.preview_image_path.name} | 方向: {'横向排布' if orientation == 'horizontal' else '竖向排布'} | 切分数: {len(boxes)}"
        )
        self._update_box_info()
        self.render_preview()

    def start_batch_process(self) -> None:
        if self.is_processing:
            return
        if not self.image_files:
            messagebox.showwarning("提示", "请先选择包含扫描图的文件夹")
            return

        self.is_processing = True
        self.progress_var.set(0)
        self.status_var.set("准备开始批量切分")
        self.worker_thread = threading.Thread(target=self._process_batch_worker, daemon=True)
        self.worker_thread.start()
        self.root.after(100, self._poll_worker_queue)

    def _process_batch_worker(self) -> None:
        total = len(self.image_files)
        success_count = 0
        error_messages: List[str] = []
        last_result: ProcessResult | None = None

        for index, image_path in enumerate(self.image_files, start=1):
            self.event_queue.put(("progress", index, total, image_path.name))
            try:
                result = export_crops(image_path)
                success_count += 1
                last_result = result
            except Exception as exc:
                error_messages.append(f"{image_path.name}: {exc}")

        self.event_queue.put(("done", success_count, total, error_messages, last_result))

    def _poll_worker_queue(self) -> None:
        try:
            while True:
                event = self.event_queue.get_nowait()
                event_type = event[0]
                if event_type == "progress":
                    _, index, total, name = event
                    self.status_var.set(f"处理中 {index}/{total}: {name}")
                    self.progress_var.set(index * 100 / total)
                elif event_type == "done":
                    _, success_count, total, error_messages, last_result = event
                    self.is_processing = False
                    self.status_var.set(f"处理完成: 成功 {success_count}/{total}")
                    self.progress_var.set(100 if total else 0)
                    if last_result is not None:
                        try:
                            preview, boxes, orientation = build_preview(last_result.source_path)
                            self.preview_info_var.set(
                                f"最近处理: {last_result.source_path.name} | 方向: {'横向排布' if orientation == 'horizontal' else '竖向排布'} | 导出: {last_result.export_count}"
                            )
                            self.preview_source_image = preview
                            self.preview_boxes = boxes
                            self.selected_box_index = 0 if boxes else None
                            self._update_box_info()
                            self.render_preview()
                        except Exception:
                            pass
                    if error_messages:
                        messagebox.showwarning(
                            "处理完成",
                            f"成功处理 {success_count}/{total} 张。\n\n以下文件处理失败:\n" + "\n".join(error_messages[:15]),
                        )
                    else:
                        output_hint = self.image_files[0].parent if self.image_files else ""
                        messagebox.showinfo("处理完成", f"已成功处理 {success_count} 张扫描图。\n输出目录位于原图同路径下。\n{output_hint}")
                    return
        except queue.Empty:
            pass

        if self.is_processing:
            self.root.after(100, self._poll_worker_queue)

    def render_preview(self) -> None:
        self.canvas.delete("all")
        if self.preview_source_image is None:
            return

        preview = self.preview_source_image.copy()
        draw = ImageDraw.Draw(preview)
        for index, box in enumerate(self.preview_boxes, start=1):
            color = "#ffcc00" if self.selected_box_index == index - 1 else "#00ff99"
            width = 12 if self.selected_box_index == index - 1 else 8
            draw.rectangle(box, outline=color, width=width)
            draw.text((box[0] + 12, box[1] + 12), str(index), fill=color)

        preview.thumbnail(PREVIEW_SIZE)
        self.preview_photo = ImageTk.PhotoImage(preview)
        canvas_width = max(1, self.canvas.winfo_width())
        canvas_height = max(1, self.canvas.winfo_height())
        offset_x = (canvas_width - preview.width) // 2
        offset_y = (canvas_height - preview.height) // 2
        self.preview_offset = (offset_x, offset_y)
        self.preview_scale = min(preview.width / self.preview_source_image.width, preview.height / self.preview_source_image.height)
        self.canvas.create_image(offset_x, offset_y, image=self.preview_photo, anchor=tk.NW)

    def _update_box_info(self) -> None:
        if self.selected_box_index is None or self.selected_box_index >= len(self.preview_boxes):
            self.box_info_var.set("未选择照片")
            return
        left, top, right, bottom = self.preview_boxes[self.selected_box_index]
        self.box_info_var.set(f"当前照片 #{self.selected_box_index + 1}: L{left} T{top} R{right} B{bottom}")

    def _canvas_to_image(self, x: int, y: int) -> tuple[int, int]:
        offset_x, offset_y = self.preview_offset
        image_x = int((x - offset_x) / max(self.preview_scale, 1e-6))
        image_y = int((y - offset_y) / max(self.preview_scale, 1e-6))
        if self.preview_source_image is None:
            return image_x, image_y
        image_x = max(0, min(self.preview_source_image.width, image_x))
        image_y = max(0, min(self.preview_source_image.height, image_y))
        return image_x, image_y

    def _hit_test_box(self, x: int, y: int) -> tuple[int | None, str | None]:
        if self.preview_source_image is None:
            return None, None
        image_x, image_y = self._canvas_to_image(x, y)
        tolerance = max(12, int(10 / max(self.preview_scale, 1e-6)))
        for index, (left, top, right, bottom) in enumerate(self.preview_boxes):
            if left <= image_x <= right and top <= image_y <= bottom:
                if abs(image_x - left) <= tolerance:
                    return index, "left"
                if abs(image_x - right) <= tolerance:
                    return index, "right"
                if abs(image_y - top) <= tolerance:
                    return index, "top"
                if abs(image_y - bottom) <= tolerance:
                    return index, "bottom"
                return index, "move"
        return None, None

    def on_canvas_press(self, event: tk.Event) -> None:
        index, mode = self._hit_test_box(event.x, event.y)
        self.selected_box_index = index
        self.drag_mode = mode
        self.drag_start_canvas = (event.x, event.y)
        self.drag_origin_box = self.preview_boxes[index] if index is not None else None
        self._update_box_info()
        self.render_preview()

    def on_canvas_drag(self, event: tk.Event) -> None:
        if self.selected_box_index is None or self.drag_mode is None or self.drag_origin_box is None or self.preview_source_image is None:
            return

        start_x, start_y = self._canvas_to_image(*self.drag_start_canvas)
        current_x, current_y = self._canvas_to_image(event.x, event.y)
        delta_x = current_x - start_x
        delta_y = current_y - start_y
        left, top, right, bottom = self.drag_origin_box

        if self.drag_mode == "move":
            width = right - left
            height = bottom - top
            new_left = max(0, min(self.preview_source_image.width - width, left + delta_x))
            new_top = max(0, min(self.preview_source_image.height - height, top + delta_y))
            box = (new_left, new_top, new_left + width, new_top + height)
        elif self.drag_mode == "left":
            box = (max(0, min(right - 30, left + delta_x)), top, right, bottom)
        elif self.drag_mode == "right":
            box = (left, top, min(self.preview_source_image.width, max(left + 30, right + delta_x)), bottom)
        elif self.drag_mode == "top":
            box = (left, max(0, min(bottom - 30, top + delta_y)), right, bottom)
        else:
            box = (left, top, right, min(self.preview_source_image.height, max(top + 30, bottom + delta_y)))

        self.preview_boxes[self.selected_box_index] = tuple(map(int, normalize_box(self.preview_source_image.size, box)))
        self._update_box_info()
        self.render_preview()

    def on_canvas_release(self, event: tk.Event) -> None:
        self.drag_mode = None
        self.drag_origin_box = None

    def on_canvas_resize(self, event: tk.Event) -> None:
        if self.preview_source_image is not None:
            self.render_preview()


def main() -> None:
    root = tk.Tk()
    app = FilmSplitterApp(root)
    root.mainloop()


def detect_json(image_path: Path) -> dict:
    with Image.open(image_path) as image_file:
        image = image_file.convert("RGB")
        orientation = detect_orientation(image)
        boxes = detect_photo_boxes(image, orientation)
        return {
            "image": str(image_path),
            "width": image.width,
            "height": image.height,
            "orientation": orientation,
            "boxes": [
                {"left": left, "top": top, "right": right, "bottom": bottom}
                for left, top, right, bottom in boxes
            ],
        }


def cli() -> bool:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--detect-json", type=Path)
    args, _ = parser.parse_known_args()
    if args.detect_json is None:
        return False

    try:
        print(json.dumps(detect_json(args.detect_json), ensure_ascii=False))
        return True
    except Exception as exc:
        print(json.dumps({"image": str(args.detect_json), "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return True


if __name__ == "__main__":
    if not cli():
        main()
