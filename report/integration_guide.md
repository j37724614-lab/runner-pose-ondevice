# integration_guide.md — wiring RunnerPoseKit into the main Flutter app (規劃書 §11)

## Current vs target

| | current | target |
|---|---|---|
| upload | Flutter → `backend.uploadVideo` → server | Flutter runs `runner_pose` on device → uploads keypoints JSON |
| tracking + HRNet | server `run_analysis()` first two stages | device `RunnerPoseEngine` |
| leg-identity / 3D / gait / overlay | server | **unchanged** — consumes uploaded keypoints |
| video | uploaded, kept on server | stays on device (optional upload for annotation) |

## Steps

1. **Plugin**: `flutter/runner_pose` — generate Pigeon messages, implement
   `RunnerPosePlugin.swift` against `RunnerPoseEngine`. Add `RunnerPoseKit` as a local
   SwiftPM dependency of the host iOS app (or vendor its sources into the pod).
2. **App**: after record/pick, run `RunnerPose.analyze(path)` → collect
   `RunnerPoseFrame`s (show progress from `frameIndex`).
3. **Upload**: `RunnerPose.toKeypointsPayload(frames, fps, w, h)` →
   `POST /analyze/keypoints` instead of the video.
4. **Feature flag**: keep both paths; A/B the results and the UX.

## Backend changes (NOT in this repo — 待辦, 規劃書 §11 / §12 #5)

- `routes/upload.py`: add `POST /analyze/keypoints` accepting the payload above +
  metadata (session, camera calibration if any).
- `core/pipeline.py`: add `PoseSource.PRECOMPUTED_2D` — skip `run_temporal_prescan`
  + HRNet, feed the uploaded keypoints straight into the leg-identity stage.
- The keypoints schema is the one `OutputSchemaTests` locks to the current HRNet
  stage output — **no new format on the server side**.

## Keypoints payload

```json
{
  "fps": 60.0,
  "frame_size": [1920, 1080],
  "frames": [
    { "frame": 0, "valid": true, "joints": [[x, y, score], ... 23 in JointName order] }
  ]
}
```

Joint order: `nose, left_eye, right_eye, left_ear, right_ear, left_shoulder,
right_shoulder, left_elbow, right_elbow, left_wrist, right_wrist, left_hip, right_hip,
left_knee, right_knee, left_ankle, right_ankle, left_big_toe, left_small_toe, left_heel,
right_big_toe, right_small_toe, right_heel`.
