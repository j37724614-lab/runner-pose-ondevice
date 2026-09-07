#!/usr/bin/env bash
#
# fetch_models.sh — gather every Core ML model RunnerPoseKit / BenchApp load at
# runtime into ./models/, then stage them into Sources/RunnerPoseKit/Resources/.
#
# Models are large binaries and are .gitignore'd (規劃書 §02, Resources/README.md).
# This script is the reproducible way to get them onto a fresh checkout — run it
# once on the Mac before `swift build` / opening BenchApp, or on Linux to refresh
# the ./models staging copy.
#
#   scripts/fetch_models.sh                 # fetch everything, then stage
#   scripts/fetch_models.sh --no-stage      # only populate ./models/
#   scripts/fetch_models.sh --scales n s    # only these YOLO scales
#   HRNET_SRC=/path/to/HRNetRunnerWholeBody23.mlpackage scripts/fetch_models.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$REPO_ROOT/models"
RES_DIR="$REPO_ROOT/Sources/RunnerPoseKit/Resources"

# ---- config -----------------------------------------------------------------
YOLO_RELEASE="v8.3.0"
YOLO_BASE_URL="https://github.com/ultralytics/yolo-ios-app/releases/download/${YOLO_RELEASE}"
YOLO_SCALES=(n s m l)

# HRNet is our own model. Default: the local runner-analysis-pipeline checkout on
# this machine. Override with HRNET_SRC=<path to .mlpackage> or point it at a URL
# with HRNET_URL=<...zip>.
HRNET_SRC="${HRNET_SRC:-/home/jeter/runner-analysis-pipeline/models/coreml/HRNetRunnerWholeBody23.mlpackage}"
HRNET_JSON_SRC="${HRNET_JSON_SRC:-/home/jeter/runner-analysis-pipeline/models/coreml/HRNetRunnerWholeBody23.conversion.json}"
HRNET_URL="${HRNET_URL:-}"

# ---- args -----------------------------------------------------------------
STAGE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-stage) STAGE=0; shift ;;
    --scales) shift; YOLO_SCALES=(); while [[ $# -gt 0 && "$1" != --* ]]; do YOLO_SCALES+=("$1"); shift; done ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\033[1;34m•\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

mkdir -p "$MODELS_DIR/coreml" "$MODELS_DIR/yolo"

# ---- HRNet-W48 wholebody-23 (S4, HRNetRunner.resourceName) ------------------
HRNET_DST="$MODELS_DIR/coreml/HRNetRunnerWholeBody23.mlpackage"
if [[ -n "$HRNET_URL" ]]; then
  log "HRNet: downloading $HRNET_URL"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/hrnet.zip" "$HRNET_URL"
  rm -rf "$HRNET_DST"
  unzip -q "$tmp/hrnet.zip" -d "$MODELS_DIR/coreml/"
  rm -rf "$tmp"
elif [[ -d "$HRNET_SRC" ]]; then
  log "HRNet: copying from $HRNET_SRC"
  rm -rf "$HRNET_DST"
  cp -R "$HRNET_SRC" "$HRNET_DST"
  [[ -f "$HRNET_JSON_SRC" ]] && cp "$HRNET_JSON_SRC" "$MODELS_DIR/coreml/"
else
  warn "HRNet source not found: $HRNET_SRC"
  warn "  set HRNET_SRC=<path to HRNetRunnerWholeBody23.mlpackage> or HRNET_URL=<zip url>"
  warn "  (produced by runner-analysis-pipeline/scripts/tools/convert_hrnet_to_coreml.py)"
fi

# ---- YOLO26 detector candidates (S0 + S2, DetectorModel.yolo26{n,s,m,l}) ----
# iOS-ready .mlpackage from ultralytics/yolo-ios-app — NOT the same as the
# ultralytics `.pt` weights used by scripts/make_prescan_reference.py.
for s in "${YOLO_SCALES[@]}"; do
  name="yolo26${s}"
  dst="$MODELS_DIR/yolo/${name}.mlpackage"
  if [[ -d "$dst" ]]; then
    log "YOLO $name: already present"
    continue
  fi
  url="${YOLO_BASE_URL}/${name}.mlpackage.zip"
  log "YOLO $name: downloading $url"
  tmp="$(mktemp -d)"
  if curl -fL --progress-bar -o "$tmp/${name}.zip" "$url"; then
    unzip -q "$tmp/${name}.zip" -d "$MODELS_DIR/yolo/"
  else
    warn "  download failed — get ${name}.mlpackage.zip manually from"
    warn "  https://github.com/ultralytics/yolo-ios-app/releases/tag/${YOLO_RELEASE}"
  fi
  rm -rf "$tmp"
done

# ---- stage into the SwiftPM resource dir -----------------------------------
if [[ "$STAGE" -eq 1 ]]; then
  mkdir -p "$RES_DIR"
  log "staging into $RES_DIR"
  [[ -d "$HRNET_DST" ]] && cp -R "$HRNET_DST" "$RES_DIR/"
  for s in "${YOLO_SCALES[@]}"; do
    src="$MODELS_DIR/yolo/yolo26${s}.mlpackage"
    [[ -d "$src" ]] && cp -R "$src" "$RES_DIR/"
  done
  log "staged: $(cd "$RES_DIR" && ls -d ./*.mlpackage 2>/dev/null | tr '\n' ' ')"
fi

# ---- summary --------------------------------------------------------------
echo
log "models/ contents:"
find "$MODELS_DIR" -maxdepth 2 \( -name '*.mlpackage' -o -name '*.pt' \) | sort | sed 's/^/    /'
echo
log "done. Next: swift build  (Mac only)"
