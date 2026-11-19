"""Load the pose-model spec code and specs from the runner-analysis-pipeline checkout.

The spec format is owned by the pipeline (core/pose_models/). These scripts load its spec.py
and simcc.py by file path instead of importing the `core` package, because `import core`
pulls in the whole server pipeline (OpenCV, PyTorch, ...), which the Mac does not need.

Pipeline location: $RUNNER_ANALYSIS_PIPELINE_ROOT, else ../runner-analysis-pipeline next to
this repo.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path
from types import ModuleType

REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLED_SPEC_DIR = REPO_ROOT / "Sources" / "RunnerPoseKit" / "Resources" / "PoseModels"


def pipeline_root() -> Path:
    root = Path(
        os.environ.get("RUNNER_ANALYSIS_PIPELINE_ROOT", REPO_ROOT.parent / "runner-analysis-pipeline")
    )
    if not (root / "core" / "pose_models" / "spec.py").is_file():
        sys.exit(
            f"pipeline checkout not found at {root} (core/pose_models/spec.py missing); "
            "set RUNNER_ANALYSIS_PIPELINE_ROOT"
        )
    return root


def _load(name: str, path: Path) -> ModuleType:
    module_spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(module_spec)
    sys.modules[name] = module  # dataclasses need the module registered while executing
    module_spec.loader.exec_module(module)
    return module


def spec_module() -> ModuleType:
    """The pipeline's core/pose_models/spec.py (stdlib only)."""
    return _load("pipeline_pose_spec", pipeline_root() / "core" / "pose_models" / "spec.py")


def simcc_module() -> ModuleType:
    """The pipeline's core/pose_models/simcc.py (numpy only): the SimCC reference decoder."""
    return _load("pipeline_pose_simcc", pipeline_root() / "core" / "pose_models" / "simcc.py")


def pipeline_spec_dir() -> Path:
    return pipeline_root() / "core" / "pose_models" / "specs"
