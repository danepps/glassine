#!/bin/zsh
# make-icon.sh — regenerate every Glassine icon artifact from scripts/make-icon.swift.
#
# Produces, under Support/:
#   Glassine.icns               legacy icon, light artwork (macOS 14/15 fallback)
#   Glassine.icon/              Icon Composer package, light + dark appearances
#   Assets.car                  compiled asset catalog for macOS 26 (Tahoe)
#   Glassine-partial-Info.plist keys actool says the app's Info.plist needs
#
# macOS 26 picks the light/dark variant out of Assets.car (via CFBundleIconName);
# older systems fall back to Glassine.icns (via CFBundleIconFile).

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
SUPPORT="$ROOT/Support"
RENDER="$SCRIPT_DIR/make-icon.swift"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glassine-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ICON_NAME=Glassine                   # must match CFBundleIconName / CFBundleIconFile
ICONPKG="$SUPPORT/$ICON_NAME.icon"
DEPLOY_TARGET=14.0                   # matches LSMinimumSystemVersion in Info.plist

mkdir -p "$SUPPORT"

# ---------------------------------------------------------------- 1. artwork
# Icon Composer layers are full-bleed and get masked to the icon shape by the
# system; the legacy .icns art uses the inset macOS icon grid.
echo "==> rendering Icon Composer layers"
rm -rf "$ICONPKG"
mkdir -p "$ICONPKG/Assets"
swift "$RENDER" "$ICONPKG/Assets/Glassine-Light-1024.png" --full-bleed
swift "$RENDER" "$ICONPKG/Assets/Glassine-Dark-1024.png"  --full-bleed --dark

# ------------------------------------------------------------------ 2. .icns
# Every size is rendered at its own resolution rather than downsampled from
# 1024: below 128 px the rims and the four coloured rules are sub-pixel, and
# make-icon.swift widens them, straightens the top leaf and drops fanned leaves
# to suit.
echo "==> building $ICON_NAME.icns"
ICONSET="$WORK/$ICON_NAME.iconset"
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512 1024; do
  swift "$RENDER" "$WORK/glassine-legacy-$px.png" --size "$px"
done
# size:name pairs — @2x entries are the same pixel size as the next base size up
for pair in \
  16:icon_16x16.png \
  32:icon_16x16@2x.png \
  32:icon_32x32.png \
  64:icon_32x32@2x.png \
  128:icon_128x128.png \
  256:icon_128x128@2x.png \
  256:icon_256x256.png \
  512:icon_256x256@2x.png \
  512:icon_512x512.png \
  1024:icon_512x512@2x.png
do
  cp "$WORK/glassine-legacy-${pair%%:*}.png" "$ICONSET/${pair#*:}"
done
iconutil -c icns "$ICONSET" -o "$SUPPORT/$ICON_NAME.icns"

# ------------------------------------------------------------- 3. icon.json
# Both appearances ship as full-bleed layers; `opacity-specializations` swaps
# which one is visible. An entry with no "appearance" key is the default
# (light) value, and the "dark" entry overrides it in dark mode.
echo "==> writing $ICON_NAME.icon/icon.json"
cat > "$ICONPKG/icon.json" <<'JSON'
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.23529,0.29020,0.35294,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "Glassine-Dark-1024.png",
          "name" : "Dark Artwork",
          "opacity-specializations" : [
            {
              "value" : 0
            },
            {
              "appearance" : "dark",
              "value" : 1
            }
          ]
        },
        {
          "image-name" : "Glassine-Light-1024.png",
          "name" : "Default Artwork",
          "opacity-specializations" : [
            {
              "value" : 1
            },
            {
              "appearance" : "dark",
              "value" : 0
            }
          ]
        }
      ],
      "name" : "Page",
      "shadow" : {
        "kind" : "neutral",
        "opacity" : 0.5
      },
      "translucency" : {
        "enabled" : false,
        "value" : 0.5
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
JSON

# ------------------------------------------------------------ 4. Assets.car
# actool takes the .icon package directly as its document — no .xcassets
# wrapper needed. It also drops a loose .icns into the output dir, which is why
# we compile into $WORK and copy only what we want back into Support/.
echo "==> compiling Assets.car"
mkdir -p "$WORK/car"
ACTOOL_LOG="$(xcrun actool "$ICONPKG" \
  --compile "$WORK/car" \
  --app-icon "$ICON_NAME" \
  --include-all-app-icons \
  --platform macosx \
  --minimum-deployment-target "$DEPLOY_TARGET" \
  --target-device mac \
  --skip-app-store-deployment \
  --output-partial-info-plist "$WORK/car/partial-Info.plist" \
  --errors --warnings \
  --output-format human-readable-text 2>&1)"
print -r -- "$ACTOOL_LOG"
# actool still writes Assets.car for some errors (the four-group limit, say),
# so a zero exit status alone does not mean the icon compiled correctly.
if print -r -- "$ACTOOL_LOG" | grep -qi "error:"; then
  echo "actool reported errors - refusing to install Assets.car" >&2
  exit 1
fi

cp "$WORK/car/Assets.car" "$SUPPORT/Assets.car"
cp "$WORK/car/partial-Info.plist" "$SUPPORT/$ICON_NAME-partial-Info.plist"

echo
echo "wrote $SUPPORT/$ICON_NAME.icns"
echo "wrote $ICONPKG/"
echo "wrote $SUPPORT/Assets.car"
echo "wrote $SUPPORT/$ICON_NAME-partial-Info.plist  (keys the app Info.plist needs)"
