# testdata

Git-ignored except this file, `.gitkeep`s, and `prescan_reference/**/*.json`.

```
videos/                     3–5 fixed source clips (規劃書 §05 P0). NOT clipped.
prescan_reference/<scale>/  <video>_valid_ranges.json  — S0 parity baseline per detector scale
manifest.json               clip list + properties + which conditions each covers
```

## manifest.json template

```json
{
  "videos": [
    {
      "file": "meet_2026_lane4.mp4",
      "resolution": [1920, 1080],
      "fps": 60,
      "duration_s": 42.0,
      "conditions": ["side-on", "bright", "single runner", "moderate motion blur"],
      "notes": "prescan on n/s/m/l kept ~0.55"
    }
  ],
  "prescan_params_source": "running-analysis-backend config as of <date>",
  "prescan_params": { "stride": 8, "min_height": 40, "buffer_sec": 1.0, "max_gap_sec": 1.0 }
}
```

Fill `prescan_params` from the real backend before running `make_prescan_reference.py`
(規劃書 §12 待你確認 #2).
