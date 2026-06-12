#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
SOURCE_PACKAGES="${SOURCE_PACKAGES:-$DERIVED_DATA/SourcePackages}"
MODULE_CACHE="${MODULE_CACHE:-$ROOT/build/ModuleCache.noindex}"
SWIFTPM_MODULE_CACHE="${SWIFTPM_MODULE_CACHE:-$ROOT/build/swiftpm-module-cache}"
RESULT_BUNDLE="${RESULT_BUNDLE:-$ROOT/build/ResultBundles/xcode-test.xcresult}"

mkdir -p "$DERIVED_DATA" "$SOURCE_PACKAGES" "$MODULE_CACHE" "$SWIFTPM_MODULE_CACHE" "$(dirname "$RESULT_BUNDLE")"
rm -rf "$RESULT_BUNDLE"

package_resolution_flags=()
if [[ "${ALLOW_PACKAGE_RESOLUTION:-0}" != "1" ]]; then
    package_resolution_flags=(-disableAutomaticPackageResolution)
fi

export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

xcodebuild \
    -project GhostPepper.xcodeproj \
    -scheme GhostPepper \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    "${package_resolution_flags[@]}" \
    -resultBundlePath "$RESULT_BUNDLE" \
    CODE_SIGNING_ALLOWED=NO \
    MODULE_CACHE_DIR="$MODULE_CACHE" \
    -skipMacroValidation \
    "$@" \
    test
