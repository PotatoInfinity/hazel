#!/bin/sh
# Build HazelWallpaperExtension.appex (video lockscreen renderer).
# The appex is MH_EXECUTE like a tiny app (NOT an MH_BUNDLE): it contains a
# Mach-O executable plus an Info.plist declaring the com.apple.wallpaper
# extension point. No pbxproj changes; the app-side worker embeds the
# resulting bundle (see report).
set -e

# Standalone dev build. The Xcode "Build Hazel.saver" phase inlines an
# equivalent sequence (kept in sync manually); this script is for iterating on
# the appex without a full app build. Env overrides keep both paths aligned.
#
# -fapplication-extension is LOAD-BEARING: without it the binary links the
# non-extension Foundation entry and ExtensionFoundation's _EXRunningExtension
# singleton traps (MainActor.assumeIsolated SIGTRAP) at process start.
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HERE/build"
ARCHS="${ARCHS:-arm64}"
DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.2}"
SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path)}"
APPEX="$STAGE/HazelWallpaperExtension.appex"
CONTENTS="$APPEX/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APPEX"
mkdir -p "$MACOS"

# shellcheck disable=SC2086
xcrun swiftc -O \
  -Xfrontend -application-extension \
  -target ${ARCHS%% *}-apple-macosx${DEPLOY_TARGET} \
  -sdk "$SDK_PATH" \
  "$HERE"/Sources/*.swift \
  -import-objc-header "$HERE/HazelExtension-Bridging-Header.h" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework ExtensionFoundation \
  -framework IOSurface \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$MACOS/HazelWallpaperExtension"

cp "$HERE/Info.plist" "$CONTENTS/Info.plist"

/usr/bin/codesign --force --sign - \
  --identifier "com.live.hazel.wallpaper-extension" \
  --entitlements "$HERE/HazelWallpaperExtension.entitlements" \
  "$APPEX"

echo "BUILT: $APPEX"
/usr/bin/codesign -vvv "$APPEX"
/usr/bin/file "$MACOS/HazelWallpaperExtension"
