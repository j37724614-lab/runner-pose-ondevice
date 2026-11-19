"""Write the SimCC decoder fixture that SimCCDecoderTests checks the Swift decoder against.

The expected values come from the pipeline's reference decoder (core/pose_models/simcc.py),
so the Swift `SimCCKeypointDecoder.decodeCrop` and the server decode SimCC output identically.

    python scripts/pose_models/make_simcc_fixture.py
"""

from __future__ import annotations

import json

import numpy as np
from pipeline_specs import REPO_ROOT, simcc_module

OUT = REPO_ROOT / "Tests" / "RunnerPoseKitTests" / "Fixtures" / "simcc" / "simcc_decode_cases.json"


def _peaked(rng, keypoints: int, bins: int) -> np.ndarray:
    """Smooth random vectors with one clear peak per keypoint, like a trained SimCC head."""
    centres = rng.integers(0, bins, size=keypoints)
    positions = np.arange(bins)[None, :]
    widths = rng.uniform(1.5, 4.0, size=(keypoints, 1))
    heights = rng.uniform(0.2, 1.0, size=(keypoints, 1))
    values = heights * np.exp(-0.5 * ((positions - centres[:, None]) / widths) ** 2)
    return values + rng.normal(0.0, 0.01, size=values.shape)


def cases() -> list[dict]:
    decode = simcc_module().decode_simcc
    rng = np.random.default_rng(20261119)
    built = []
    specs = [
        ("rtmpose_like_ratio2", 23, 96, 128, 2.0),
        ("ratio_1_5", 6, 45, 60, 1.5),
    ]
    for name, keypoints, x_bins, y_bins, ratio in specs:
        simcc_x = _peaked(rng, keypoints, x_bins)
        simcc_y = _peaked(rng, keypoints, y_bins)
        if name == "ratio_1_5":
            simcc_x[2] = -np.abs(simcc_x[2]) - 0.1  # no positive score: must come out (-1, -1)
        points, scores = decode(simcc_x, simcc_y, ratio)
        built.append(
            {
                "name": name,
                "split_ratio": ratio,
                "simcc_x": np.round(simcc_x, 6).tolist(),
                "simcc_y": np.round(simcc_y, 6).tolist(),
                "expected_points": points.tolist(),
                "expected_scores": scores.tolist(),
            }
        )
    # Recompute expectations from the rounded inputs the Swift test will actually read.
    for case in built:
        points, scores = decode(
            np.array(case["simcc_x"]), np.array(case["simcc_y"]), case["split_ratio"]
        )
        case["expected_points"] = points.tolist()
        case["expected_scores"] = scores.tolist()
    return built


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"cases": cases()}, separators=(",", ":")) + "\n", encoding="utf-8")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
