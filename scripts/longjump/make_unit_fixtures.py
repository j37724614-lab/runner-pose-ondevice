"""Unit fixtures for LongJumpKit: numpy / scipy / OpenCV / Python behaviour the Swift port mirrors.

The server's long-jump code (runner-analysis-pipeline core/longjump/) leans on numpy, scipy and
OpenCV.  LongJumpKit re-implements the few operations it uses in plain Swift; this script records
what the real libraries return on small synthetic inputs, so every Swift primitive is checked
value by value (no image files, no pipeline checkout needed).

    /home/jeter/.conda/envs/yolo_new/bin/python scripts/longjump/make_unit_fixtures.py

Writes Tests/LongJumpKitTests/Fixtures/unit/*.json (committed; small).  Re-run after changing
the cases or upgrading numpy / scipy / OpenCV, and commit the result.

Encoding: NaN / +inf / -inf are the strings "nan" / "inf" / "-inf" (JSON has no NaN).
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import cv2
import numpy as np
import scipy
from scipy.ndimage import median_filter

REPO_ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = REPO_ROOT / "Tests" / "LongJumpKitTests" / "Fixtures" / "unit"


def enc(value):
    """JSON-safe copy: numpy -> Python, non-finite floats -> strings."""
    if isinstance(value, dict):
        return {str(k): enc(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [enc(v) for v in value]
    if isinstance(value, np.ndarray):
        return enc(value.tolist())
    if isinstance(value, (np.bool_, bool)):
        return bool(value)
    if isinstance(value, (np.integer, int)):
        return int(value)
    if isinstance(value, (np.floating, float)):
        value = float(value)
        if math.isnan(value):
            return "nan"
        if math.isinf(value):
            return "inf" if value > 0 else "-inf"
        return value
    return value


def fnv1a64(data: bytes) -> str:
    """64-bit FNV-1a as 16 hex digits (LongJumpKit's FNV1a64 must give the same)."""
    h = 0xCBF29CE484222325
    for byte in data:
        h ^= byte
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def fnv1a64_rows(array: np.ndarray) -> str:
    """Hash of a large uint8 image: FNV-1a 64 of every row (all channels, row-major), then
    FNV-1a 64 of those row hashes as little-endian bytes.  LongJumpKit's FNV1a64.rows does the
    same; vectorised over rows here so a 4096x4096x3 image takes a second, not minutes."""
    rows = np.ascontiguousarray(array, dtype=np.uint8).reshape(array.shape[0], -1)
    h = np.full(rows.shape[0], 0xCBF29CE484222325, dtype=np.uint64)
    prime = np.uint64(0x100000001B3)
    with np.errstate(over="ignore"):
        for column in range(rows.shape[1]):
            h = (h ^ rows[:, column].astype(np.uint64)) * prime
    return fnv1a64(h.astype("<u8").tobytes())


def write(name: str, document: dict) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{name}.json"
    path.write_text(json.dumps(enc(document), indent=1) + "\n", encoding="utf-8")
    print(f"{path.relative_to(REPO_ROOT)}: {path.stat().st_size // 1024} KiB")


# --------------------------------------------------------------------------- numerics


def numerics(rng: np.random.Generator) -> dict:
    arrays = [
        rng.normal(0, 10, size=n).round(rng.integers(0, 4)) for n in (1, 2, 3, 5, 8, 13, 30, 61)
    ]
    arrays.append(np.array([3.0, 3.0, 1.0, 1.0, 2.0, 2.0, 2.0, 5.0, 5.0]))  # ties
    arrays.append(np.array([0.0, -0.0, 1e-300, -1e-300, 7.5]))

    with_nan = [
        np.array([np.nan, 1.0, np.nan, np.nan, 4.0, np.nan]),
        np.array([1.0, np.nan, 3.0]),
        np.array([np.nan, np.nan, 2.0]),
        np.array([np.nan, np.nan]),
        np.array([np.nan, 5.0, np.nan]),
        np.array([2.0, 4.0, np.inf, np.nan, 1.0]),
        rng.normal(0, 3, size=25),
    ]
    with_nan[-1][rng.choice(25, size=7, replace=False)] = np.nan

    fill = [{"input": a, "output": _fill_nan(a)} for a in with_nan + arrays[:4]]
    gradient = [{"input": a, "output": np.gradient(a)} for a in arrays + with_nan if len(a) >= 2]
    medfilt = [
        {"input": a, "size": size, "output": median_filter(a, size=size, mode="nearest")}
        for a in arrays
        for size in (3, 5, 9)
    ]
    percentile = [
        {"input": a, "q": q, "output": np.percentile(a, q)}
        for a in arrays
        for q in (0.0, 12.5, 50.0, 80.0, 95.0, 100.0)
    ]
    median = [{"input": a, "output": np.median(a)} for a in arrays]
    nan_stats = [
        {
            "input": a,
            "nanmedian": np.nanmedian(a) if np.isfinite(a).any() or np.isinf(a).any() else np.nan,
            "nanmean": np.nanmean(a) if (~np.isnan(a)).any() else np.nan,
            "nanmax": np.nanmax(a) if (~np.isnan(a)).any() else np.nan,
            "nanmin": np.nanmin(a) if (~np.isnan(a)).any() else np.nan,
            "nanargmin": int(np.nanargmin(a)) if (~np.isnan(a)).any() else None,
            "nanargmax": int(np.nanargmax(a)) if (~np.isnan(a)).any() else None,
            "argmin": int(np.argmin(a)),
            "argmax": int(np.argmax(a)),
        }
        for a in with_nan + arrays
    ]
    # Python's round() on a float vs numpy's round on np.float64 (round(np.float64(x), n) uses
    # numpy's algorithm: multiply, round half to even, divide).
    values = [
        0.5, 1.5, 2.5, -0.5, -1.5, 2.675, 1.005, 0.125, 0.375, 1234.5678, -3.14159, 1e-7,
        0.0449999, 0.045, 0.055, 2.0000005, 13.95, 6.025, 9.995, -2.675,
    ]
    values += list(rng.normal(0, 5, size=40))
    rounding = [
        {
            "x": x,
            "digits": digits,
            "python": round(float(x), digits),
            "numpy": float(round(np.float64(x), digits)),
        }
        for x in values
        for digits in (0, 1, 2, 3, 4)
    ]
    python_int_round = [{"x": x, "output": round(float(x))} for x in values]
    return {
        "fill_nan": fill,
        "gradient": gradient,
        "median_filter": medfilt,
        "percentile": percentile,
        "median": median,
        "nan_stats": nan_stats,
        "round": rounding,
        "round_int": python_int_round,
        "versions": {"numpy": np.__version__, "scipy": scipy.__version__},
    }


def _fill_nan(values: np.ndarray) -> np.ndarray:
    filled = np.asarray(values, float).copy()
    finite = np.isfinite(filled)
    if finite.sum() >= 2:
        filled[~finite] = np.interp(np.flatnonzero(~finite), np.flatnonzero(finite), filled[finite])
    return filled


# --------------------------------------------------------------------------- OpenCV


def mask_runs(mask: np.ndarray) -> list:
    """[[row, start, end), ...] of the non-zero pixels."""
    runs = []
    for y, row in enumerate(np.asarray(mask) != 0):
        padded = np.concatenate([[False], row, [False]])
        edges = np.flatnonzero(padded[1:] != padded[:-1])
        runs.extend([y, int(a), int(b)] for a, b in zip(edges[::2], edges[1::2]))
    return runs


def random_mask(rng, height: int, width: int, density: float, blobs: int) -> np.ndarray:
    mask = (rng.random((height, width)) < density).astype(np.uint8)
    for _ in range(blobs):
        y, x = rng.integers(0, height), rng.integers(0, width)
        h, w = rng.integers(1, max(2, height // 3)), rng.integers(1, max(2, width // 3))
        mask[y : y + h, x : x + w] = 1
    return mask


def opencv(rng: np.random.Generator) -> dict:
    # BGR -> HSV (8-bit): every one of the 2^24 colours, as a hash, plus readable samples.
    b, g, r = np.meshgrid(np.arange(256), np.arange(256), np.arange(256), indexing="ij")
    every = np.stack([b, g, r], axis=-1).astype(np.uint8).reshape(4096, 4096, 3)
    hsv_every = cv2.cvtColor(every, cv2.COLOR_BGR2HSV)
    samples = rng.integers(0, 256, size=(1, 3000, 3), dtype=np.uint8)
    samples[0, :20] = [[0, 0, 0], [255, 255, 255], [0, 0, 255], [0, 255, 0], [255, 0, 0],
                       [128, 128, 128], [0, 255, 255], [255, 0, 255], [255, 255, 0], [1, 2, 3],
                       [10, 10, 200], [200, 10, 10], [10, 200, 10], [90, 60, 30], [30, 60, 90],
                       [254, 255, 255], [0, 0, 1], [1, 0, 0], [0, 1, 0], [77, 77, 78]]
    hsv_samples = cv2.cvtColor(samples, cv2.COLOR_BGR2HSV)

    morph = []
    for height, width, density, blobs in ((12, 17, 0.5, 0), (30, 40, 0.3, 3), (25, 25, 0.1, 5),
                                          (40, 31, 0.6, 2), (9, 50, 0.45, 1)):
        mask = random_mask(rng, height, width, density, blobs)
        mask[0, :] = 1  # touches the border: checks the default border handling
        morph.append(
            {
                "width": width,
                "height": height,
                "input": mask_runs(mask),
                "open3": mask_runs(cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))),
                "close5": mask_runs(cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))),
                "dilate13": mask_runs(cv2.dilate(mask, np.ones((13, 13), np.uint8))),
                "erode3": mask_runs(cv2.erode(mask, np.ones((3, 3), np.uint8))),
            }
        )

    components = []
    for height, width, density, blobs in ((20, 30, 0.35, 2), (40, 40, 0.15, 6), (16, 64, 0.5, 0),
                                          (33, 21, 0.05, 8)):
        mask = random_mask(rng, height, width, density, blobs)
        count, labels, stats, centroids = cv2.connectedComponentsWithStats(mask)
        components.append(
            {
                "width": width,
                "height": height,
                "input": mask_runs(mask),
                "count": count,
                "labels": labels,
                "stats": stats,  # x, y, width, height, area per label; label 0 = background
                "centroids": centroids,
            }
        )

    distance = []
    for height, width, density, blobs in ((15, 20, 0.85, 0), (40, 50, 0.97, 0), (30, 30, 0.995, 0),
                                          (1, 30, 0.8, 0), (25, 3, 0.9, 0)):
        mask = (rng.random((height, width)) < density).astype(np.uint8)
        dist = cv2.distanceTransform(mask, cv2.DIST_L2, 5)
        distance.append(
            {"width": width, "height": height, "input": mask_runs(mask), "output": dist}
        )
    # all non-zero: no zero pixel anywhere
    full = np.ones((6, 7), np.uint8)
    distance.append(
        {"width": 7, "height": 6, "input": mask_runs(full), "output": cv2.distanceTransform(full, cv2.DIST_L2, 5)}
    )

    lines = []
    for count in (2, 3, 7, 12, 40, 150):
        ys = np.arange(count, dtype=np.float32) + rng.integers(0, 500)
        xs = (0.3 * ys + rng.normal(0, 1.5, size=count) + rng.integers(0, 900)).round()
        if count > 10:
            xs[rng.choice(count, size=count // 8, replace=False)] += rng.normal(0, 25, size=count // 8).round()
        points = np.column_stack([xs, ys]).astype(np.float32)
        lines.append(
            {"points": points, "output": cv2.fitLine(points, cv2.DIST_HUBER, 0, 0.01, 0.01).ravel()}
        )
    vertical = np.column_stack([np.full(9, 100.0), np.arange(9) + 40.0]).astype(np.float32)
    lines.append({"points": vertical, "output": cv2.fitLine(vertical, cv2.DIST_HUBER, 0, 0.01, 0.01).ravel()})

    homographies = []
    base_image = np.array([[466.0, 620.0], [1117.3, 620.8], [1217.9, 700.1], [83.1, 695.7],
                           [900.3, 620.5], [850.2, 698.7]])
    base_world = np.array([[0.0, 0.0], [9.3, 0.0], [9.3, 5.2], [0.0, 5.2], [6.2, 0.0], [6.2, 5.2]])
    for count in (4, 5, 6):
        for noise in (0.0, 0.8, 3.0):
            image_points = base_image[:count] + rng.normal(0, noise, size=(count, 2))
            world_points = base_world[:count]
            matrix, _ = cv2.findHomography(image_points, world_points, 0)
            probe = np.column_stack([rng.uniform(0, 1920, 12), rng.uniform(400, 1080, 12)])
            world = cv2.perspectiveTransform(probe.reshape(-1, 1, 2), matrix).reshape(-1, 2)
            back = cv2.perspectiveTransform(
                world.reshape(-1, 1, 2), np.linalg.inv(matrix)
            ).reshape(-1, 2)
            homographies.append(
                {
                    "image_points": image_points,
                    "world_points": world_points,
                    "matrix": matrix,
                    "probe_image": probe,
                    "probe_world": world,
                    "probe_back": back,
                }
            )

    return {
        "versions": {"opencv": cv2.__version__},
        "hsv": {
            "every_color_layout": "4096x4096 BGR image; pixel i = (b, g, r) = (i >> 16, (i >> 8) & 255, i & 255)",
            "every_color_hsv_fnv1a64_rows": fnv1a64_rows(hsv_every),
            "samples_bgr": samples[0],
            "samples_hsv": hsv_samples[0],
        },
        "morphology": morph,
        "connected_components": components,
        "distance_transform_l2_5": distance,
        "fit_line_huber": lines,
        "homography": homographies,
    }


def main() -> None:
    rng = np.random.default_rng(20261119)
    write("numerics", numerics(rng))
    write("opencv", opencv(rng))
    print("FNV-1a check:", fnv1a64(b"long jump"))


if __name__ == "__main__":
    main()
