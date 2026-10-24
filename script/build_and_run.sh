#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
BUILD_DIR="$PROJECT_ROOT/build/OCRFixDerivedData"
APP_BUNDLE="$BUILD_DIR/Build/Products/Debug/Aquarius.app"
case "$MODE" in
    run|--verify|--debug|--logs|--telemetry) ;;
    *) printf 'Usage: %s [run|--verify|--debug|--logs|--telemetry]\n' "$0" >&2; exit 2 ;;
esac

# Keep the original app bundle and all build artifacts in place.
pkill -x Aquarius >/dev/null 2>&1 || true
xcodebuild -project "$PROJECT_ROOT/Aquarius.xcodeproj" \
    -scheme Aquarius -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DIR" build

case "$MODE" in
    --debug)
        lldb -- "$APP_BUNDLE/Contents/MacOS/Aquarius"
        ;;
    *)
        /usr/bin/open -n "$APP_BUNDLE"
        case "$MODE" in
            --verify)
                for attempt in {1..20}; do
                    if pgrep -f "^$APP_BUNDLE/Contents/MacOS/Aquarius([[:space:]]|$)" >/dev/null; then
                        printf 'Launched %s\n' "$APP_BUNDLE"
                        exit 0
                    fi
                    sleep 0.25
                done
                printf 'Aquarius did not remain running after launch.\n' >&2
                exit 1
                ;;
            --logs)
                /usr/bin/log stream --info --style compact --predicate 'process == "Aquarius"'
                ;;
            --telemetry)
                /usr/bin/log stream --info --style compact --predicate 'subsystem == "lex.Aquarius"'
                ;;
        esac
        ;;
esac
