#!/bin/bash
# Build only from this checkout, including interface/model resources, using full Xcode.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 || "${1:-}" == -* ]]; then
    echo "Usage: $0 [derived-data-directory]" >&2
    exit 2
fi
derived_data="${1:-"$root/build/source"}"
case "$derived_data" in
    /*) ;;
    *) derived_data="$root/$derived_data" ;;
esac

if ! xcrun --find ibtool >/dev/null 2>&1 || ! xcrun --find momc >/dev/null 2>&1; then
    echo "Full Xcode is required; Command Line Tools alone cannot compile the interface/model resources." >&2
    echo "Select Xcode for this command with DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer." >&2
    exit 1
fi
if [[ ! -f "$root/ShortcutRecorder/ShortcutRecorder.xcodeproj/project.pbxproj" ]]; then
    echo "Initialize the pinned dependency: git submodule update --init --recursive" >&2
    exit 1
fi

xcodebuild -version
# These overrides also apply to the unchanged legacy dependency project.
xcodebuild -project "$root/Thyme.xcodeproj" -scheme ThymeNative \
    -configuration Release -sdk macosx -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=11.0 \
    GCC_VERSION=com.apple.compilers.llvm.clang.1_0 CLANG_ENABLE_MODULES=NO \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    build

app="$derived_data/Build/Products/Release/Thyme Native.app"
for resource in MainMenu.nib PreferencesWindowController.nib DataModel.mom LICENSE THIRD_PARTY_NOTICES.txt LICENSES; do
    test -e "$app/Contents/Resources/$resource"
done
for binary in "$app/Contents/MacOS/Thyme" \
    "$app/Contents/Frameworks/ShortcutRecorder.framework/ShortcutRecorder" \
    "$app/Contents/Frameworks/PTHotKey.framework/PTHotKey"; do
    test "$(lipo -archs "$binary")" = arm64
done
codesign --verify --deep --strict --verbose=2 "$app"
echo "Built from source: $app"
echo "This command does not install or launch the app. Its signature is local and ad-hoc."
