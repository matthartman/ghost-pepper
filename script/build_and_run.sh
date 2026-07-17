#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="GhostPepper"
BUNDLE_ID="com.github.matthartman.ghostpepper"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build/run-derived"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild build \
    -project "$ROOT_DIR/GhostPepper.xcodeproj" \
    -scheme "$APP_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    -jobs 4 \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

open_onboarding() {
    defaults write "$BUNDLE_ID" onboardingCompleted -bool false
    /usr/bin/open -n "$APP_BUNDLE" --args --force-onboarding
}

case "$MODE" in
    run)
        open_app
        ;;
    onboarding|--onboarding)
        open_onboarding
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        sleep 1
        pgrep -x "$APP_NAME" >/dev/null
        ;;
    *)
        echo "usage: $0 [run|onboarding|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac
