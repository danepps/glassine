#!/bin/zsh
# Build Glassine.app into ./build.
# Usage: ./build.sh [--run] [--debug] [--adhoc] [--notarize]
set -euo pipefail
ROOT="${0:A:h}"
CONFIG=release
RUN=0
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --run) RUN=1 ;;
    --debug) CONFIG=debug ;;
    --adhoc) ADHOC=1 ;;   # skip Developer ID signing (faster, offline)
    --notarize) NOTARIZE=1 ;;   # submit to Apple, wait, staple (needs "notary" keychain profile)
    *) echo "unknown option: $arg (use --run, --debug, --adhoc, --notarize)" >&2; exit 2 ;;
  esac
done
NOTARIZE=${NOTARIZE:-0}
if [[ $NOTARIZE -eq 1 && ( $ADHOC -eq 1 || "$CONFIG" != release ) ]]; then
  echo "--notarize requires a Developer ID release build (no --adhoc, no --debug)" >&2
  exit 2
fi
echo "==> $CONFIG build, $([[ $ADHOC -eq 1 ]] && echo ad-hoc || echo 'Developer ID') signing$([[ $NOTARIZE -eq 1 ]] && echo ', notarize')"

# AppKit chooses its native design from the executable's linked SDK version.
# Some Swift drivers pass only --sysroot to Clang when linking; Clang then
# records the deployment target as the SDK and enables the older tab design.
# Give the linker driver an explicit -isysroot as well as SwiftPM's SDK.
BUILD_SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c "$CONFIG" --package-path "$ROOT" --sdk "$BUILD_SDK" \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot \
  -Xswiftc -Xclang-linker -Xswiftc "$BUILD_SDK"

BINARY="$ROOT/.build/$CONFIG/Glassine"
LINKED_SDK="$(xcrun vtool -show-build "$BINARY" | awk '$1 == "sdk" { print $2 }')"
if [[ "$LINKED_SDK" != "$BUILD_SDK_VERSION" ]]; then
  echo "Linked SDK $LINKED_SDK differs from build SDK $BUILD_SDK_VERSION; refusing to package an app with a different native appearance." >&2
  exit 1
fi
echo "Verified linked macOS SDK: $LINKED_SDK"

APP="$ROOT/build/Glassine.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Glassine"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f "$ROOT/Support/Glassine.icns" ]]; then
  cp "$ROOT/Support/Glassine.icns" "$APP/Contents/Resources/Glassine.icns"
fi
for icon in MarkdownDocument PDFDocument; do
  cp "$ROOT/Support/$icon.icns" "$APP/Contents/Resources/$icon.icns"
done
if [[ -f "$ROOT/Support/Assets.car" ]]; then
  cp "$ROOT/Support/Assets.car" "$APP/Contents/Resources/Assets.car"
fi

# Sparkle. `swift build` links against the SwiftPM binary artifact but, unlike
# Xcode, embeds nothing, so the framework is copied in by hand; the target's
# linkerSettings add the matching @executable_path/../Frameworks rpath. ditto
# preserves the versioned bundle's symlinks (cp -R would too, but ditto also
# keeps extended attributes, which the existing signature depends on).
SPARKLE_FW=( "$ROOT"/.build/artifacts/*/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework(N/) )
if (( ${#SPARKLE_FW} == 0 )); then
  echo "Sparkle.framework not found under $ROOT/.build/artifacts" >&2
  echo "Run: swift package resolve --package-path $ROOT" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "${SPARKLE_FW[1]}" "$APP/Contents/Frameworks/Sparkle.framework"

# Developer ID signing with hardened runtime when the certificate is in the
# keychain (needed for notarization and Sparkle updates); ad-hoc otherwise.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [[ -n "$IDENTITY" && $ADHOC -eq 0 ]]; then
  SIGN_ID="$IDENTITY"
  SIGN_OPTS=(--options runtime --timestamp)
else
  SIGN_ID="-"
  SIGN_OPTS=()
fi

# Sparkle.framework is a bundle of bundles (Autoupdate, Updater.app, two XPC
# services). It must be signed inside out, and before the outer app, or
# `codesign --verify --deep --strict` rejects the result. Order and flags per
# https://sparkle-project.org/documentation/sandboxing/ -- note Sparkle warns
# against signing the app itself with --deep.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$SPARKLE/XPCServices/Installer.xpc"
codesign --force "${SIGN_OPTS[@]}" --preserve-metadata=entitlements \
  --sign "$SIGN_ID" "$SPARKLE/XPCServices/Downloader.xpc"
codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$SPARKLE/Autoupdate"
codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$SPARKLE/Updater.app"
codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${SIGN_OPTS[@]}" --sign "$SIGN_ID" "$APP"
if [[ "$SIGN_ID" == "-" ]]; then
  echo "Signed ad-hoc"
else
  echo "Signed with: $SIGN_ID"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if [[ $NOTARIZE -eq 1 ]]; then
  if [[ -z "$IDENTITY" || $ADHOC -eq 1 ]]; then
    echo "--notarize needs a Developer ID signature" >&2; exit 1
  fi
  ZIP="$ROOT/build/Glassine-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile notary --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
fi

if [[ $RUN -eq 1 ]]; then
  open "$APP"
fi
