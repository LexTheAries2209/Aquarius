#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aquarius-frame-stepping.XXXXXX")"
trap 'printf "Frame stepping artifacts: %s\n" "$TASK_TEMP_DIR"' EXIT
export SWIFT_MODULECACHE_PATH="$TASK_TEMP_DIR/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TASK_TEMP_DIR/clang-module-cache"
cd "$PROJECT_ROOT"

xcrun swiftc \
    Aquarius/OCRModels.swift \
    Aquarius/OCRClipAnalyzer.swift \
    Aquarius/MediaInfoMetadata.swift \
    Aquarius/QuickTimeTMCDWriter.swift \
    Aquarius/AnalysisViewModel.swift \
    Aquarius/FrameStepKeyHandler.swift \
    work/RunFrameStepSmoke.swift \
    -o "$TASK_TEMP_DIR/frame-step-smoke"

typeset -a EXTRA_FIXTURES=()
if command -v ffmpeg >/dev/null 2>&1; then
    for RATE in 24000/1001 30000/1001; do
        FIXTURE="$TASK_TEMP_DIR/fractional-${RATE//\//-}.mov"
        ffmpeg -hide_banner -loglevel error -f lavfi \
            -i "testsrc2=size=160x90:rate=$RATE:duration=2" \
            -c:v libx264 -pix_fmt yuv420p -an "$FIXTURE"
        EXTRA_FIXTURES+=("$FIXTURE")
    done
fi

"$TASK_TEMP_DIR/frame-step-smoke" "${EXTRA_FIXTURES[@]}" "$@"
