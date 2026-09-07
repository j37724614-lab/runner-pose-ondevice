"""Shared merge logic for the S0 prescan — one Python source of truth.

Ported verbatim from runner-analysis-pipeline
scripts/tracking/prescan_filter_valid_video.py::_merge_hit_frames.

`Sources/RunnerPoseKit/Pipeline/PrescanFilter.swift::mergeHitFrames` is the Swift
port of this. `test_prescan_merge.py` checks a table of cases both must agree on;
`PrescanParityTests` (Swift) checks the same table.
"""

from __future__ import annotations


def merge_hit_frames(
    hit_frames: list[int],
    total_frames: int,
    stride: int,
    buffer_frames: int,
    max_gap_frames: int,
) -> list[dict]:
    if not hit_frames:
        return []

    ranges: list[tuple[int, int]] = []
    start = end = int(hit_frames[0])
    for frame_idx in hit_frames[1:]:
        frame_idx = int(frame_idx)
        if frame_idx - end <= max_gap_frames:
            end = frame_idx
        else:
            ranges.append((start, end))
            start = end = frame_idx
    ranges.append((start, end))

    expanded: list[tuple[int, int]] = []
    last_start = last_end = None
    for start, end in ranges:
        start = max(0, start - buffer_frames)
        end = min(max(total_frames - 1, 0), end + buffer_frames + stride - 1)
        if last_start is None:
            last_start, last_end = start, end
        elif start <= last_end + 1:
            last_end = max(last_end, end)
        else:
            expanded.append((last_start, last_end))
            last_start, last_end = start, end
    expanded.append((last_start, last_end))

    return [
        {"start_frame": int(s), "end_frame": int(e), "num_frames": int(e - s + 1)}
        for s, e in expanded
    ]


# Parity table — keep identical to PrescanParityTests.swift `mergeCases`.
PARITY_CASES = [
    # (hit_frames, total_frames, stride, buffer_frames, max_gap_frames, expected [(start,end)])
    ([], 100, 8, 15, 15, []),
    ([50], 100, 8, 15, 15, [(35, 72)]),
    ([10, 12, 14, 16], 200, 8, 8, 8, [(2, 31)]),
    ([10, 40], 200, 8, 8, 8, [(2, 25), (32, 55)]),
    ([10, 20], 200, 8, 8, 15, [(2, 35)]),
    ([5, 50], 100, 8, 30, 30, [(0, 87)]),  # ranges overlap after buffer expansion -> merge
]


if __name__ == "__main__":
    ok = True
    for hits, total, stride, buf, gap, expected in PARITY_CASES:
        got = [(r["start_frame"], r["end_frame"]) for r in merge_hit_frames(hits, total, stride, buf, gap)]
        flag = "ok " if got == expected else "FAIL"
        if got != expected:
            ok = False
        print(f"{flag} hits={hits} -> {got} (expected {expected})")
    raise SystemExit(0 if ok else 1)
