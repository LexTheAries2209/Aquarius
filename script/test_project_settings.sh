#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aquarius-project-settings.XXXXXX")"
trap 'printf "Project settings artifacts: %s\n" "$TASK_TEMP_DIR"' EXIT
export SWIFT_MODULECACHE_PATH="$TASK_TEMP_DIR/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$TASK_TEMP_DIR/clang-module-cache"
cd "$PROJECT_ROOT"

xcrun swiftc \
    Aquarius/OCRModels.swift \
    Aquarius/OCRClipAnalyzer.swift \
    Aquarius/MediaInfoMetadata.swift \
    Aquarius/QuickTimeTMCDWriter.swift \
    Aquarius/AnalysisViewModel.swift \
    work/RunProjectSettingsSmoke.swift \
    -o "$TASK_TEMP_DIR/project-settings-smoke"

"$TASK_TEMP_DIR/project-settings-smoke"
