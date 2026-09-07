#!/usr/bin/env python3
"""naive → optimized comparison table from BenchReport JSON exports (規劃書 §04 / §06).

Point BenchApp's exported `runs.json` (or a directory of per-run BenchReport JSON)
at this and it groups by (device, detector_model, compute_units, video) and reports
the optimized-vs-naive delta on the headline metrics.

Also does the §08 先導 detector table: group by detector_model × detector_cadence.
"""

from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


def load_reports(path: Path) -> list[dict]:
    if path.is_dir():
        out = []
        for p in sorted(path.glob("*.json")):
            doc = json.loads(p.read_text())
            out.extend(doc if isinstance(doc, list) else [doc])
        return out
    doc = json.loads(path.read_text())
    return doc if isinstance(doc, list) else [doc]


def key_main(r: dict) -> tuple:
    c = r["conditions"]
    return (c["deviceModel"], c["detectorModel"], c["computeUnits"], c["videoName"])


def key_detector(r: dict) -> tuple:
    c = r["conditions"]
    return (c["deviceModel"], c["detectorModel"], c["detectorCadence"])


def agg(reports: list[dict]) -> dict:
    fps = [r["totals"]["effectiveFPS"] for r in reports]
    hr = [r["stages"].get("hrnet", {}).get("mean", 0) for r in reports]
    det = [r["stages"].get("detect", {}).get("mean", 0) for r in reports]
    mem = [r["memory"]["peakMB"] for r in reports]
    return {
        "runs": len(reports),
        "efffps": statistics.median(fps) if fps else 0,
        "hrnet_ms": statistics.median(hr) if hr else 0,
        "detect_ms": statistics.median(det) if det else 0,
        "peak_mb": statistics.median(mem) if mem else 0,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, help="runs.json or a directory of BenchReport JSON")
    ap.add_argument("--mode", choices=("delta", "detector"), default="delta")
    args = ap.parse_args()

    reports = load_reports(args.reports)
    if not reports:
        raise SystemExit("no reports found")

    if args.mode == "delta":
        groups: dict[tuple, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
        for r in reports:
            groups[key_main(r)][r["conditions"]["implementationVariant"]].append(r)

        print(f"{'device / detector / cu / video':<48} {'eff.fps':>18} {'hrnet ms':>16} {'peak MB':>16}")
        for k, variants in sorted(groups.items()):
            base = agg(variants.get("naive", []))
            opt = agg(variants.get("optimized", []))
            label = " / ".join(str(x) for x in k)

            def cell(field: str) -> str:
                b, o = base[field], opt[field]
                if not b or not o:
                    return f"{o or b:.1f}"
                pct = (o - b) / b * 100
                arrow = "↑" if pct > 0 else "↓"
                return f"{b:.1f}→{o:.1f} ({arrow}{abs(pct):.0f}%)"

            print(f"{label:<48} {cell('efffps'):>18} {cell('hrnet_ms'):>16} {cell('peak_mb'):>16}")

    else:  # detector selection table (§08 先導)
        groups2: dict[tuple, list[dict]] = defaultdict(list)
        for r in reports:
            groups2[key_detector(r)].append(r)
        print(f"{'device / model / cadence':<40} {'runs':>5} {'eff.fps':>9} {'detect ms':>10} {'hrnet ms':>9} {'peak MB':>9}")
        for k, rs in sorted(groups2.items()):
            a = agg(rs)
            print(f"{' / '.join(str(x) for x in k):<40} {a['runs']:>5} {a['efffps']:>9.1f} "
                  f"{a['detect_ms']:>10.2f} {a['hrnet_ms']:>9.2f} {a['peak_mb']:>9.0f}")


if __name__ == "__main__":
    main()
