"""Copy the phone-runnable pose model specs from the pipeline into the app's resources.

The pipeline (core/pose_models/specs/) is the source of truth. A spec is copied when it has a
`coreml` section and is not a template. Each one is validated with the pipeline's own parser
first.

    python scripts/pose_models/sync_pose_specs.py           # copy
    python scripts/pose_models/sync_pose_specs.py --check   # exit 1 if the bundled copies differ
"""

from __future__ import annotations

import argparse
import json
import sys

from pipeline_specs import BUNDLED_SPEC_DIR, pipeline_spec_dir, spec_module


def phone_specs() -> dict[str, str]:
    """{file name: JSON text} for the pipeline specs the phone should bundle."""
    parse_spec = spec_module().parse_spec
    wanted = {}
    for path in sorted(pipeline_spec_dir().glob("*.json")):
        text = path.read_text(encoding="utf-8")
        spec = parse_spec(json.loads(text), source=str(path))
        if spec.raw.get("coreml") is not None and spec.status != "template":
            wanted[path.name] = text
    return wanted


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true", help="only report differences")
    args = parser.parse_args()

    wanted = phone_specs()
    bundled = {p.name: p.read_text(encoding="utf-8") for p in BUNDLED_SPEC_DIR.glob("*.json")}
    stale = sorted(name for name in wanted if bundled.get(name) != wanted[name])
    extra = sorted(name for name in bundled if name not in wanted)

    if args.check:
        for name in stale:
            print(f"out of date or missing: {name}")
        for name in extra:
            print(f"bundled but not a phone spec in the pipeline: {name}")
        print("specs in sync" if not stale and not extra else "run sync_pose_specs.py to update")
        sys.exit(1 if stale or extra else 0)

    BUNDLED_SPEC_DIR.mkdir(parents=True, exist_ok=True)
    for name in stale:
        (BUNDLED_SPEC_DIR / name).write_text(wanted[name], encoding="utf-8")
        print(f"copied {name}")
    for name in extra:
        print(f"left in place (not in the pipeline): {name}; delete it if it is obsolete")
    if not stale:
        print("specs already in sync")


if __name__ == "__main__":
    main()
