#!/bin/zsh
# Build the iOS app. Regenerates iOS/Glassine.xcodeproj from iOS/project.yml
# every time (the project is gitignored; project.yml is the source of truth),
# then builds with xcodebuild into iOS/DerivedData.
#
# Usage: ./build-ios.sh [--sim [name]] [--device] [--run] [--clean] [--test]
#                       [--screenshot /abs/path.png] [--dark|--light]
#                       [-- <args passed to the app on launch>]
set -euo pipefail
ROOT="${0:A:h}"

SIM_NAME="iPad Pro 13-inch (M5)"
DEVICE=0
RUN=0
CLEAN=0
TEST=0
SHOT=""
APPEARANCE=""
APP_ARGS=()

while (( $# )); do
  case "$1" in
    --sim)
      # optional simulator name may follow
      if [[ ${2-} != "" && ${2-} != --* ]]; then SIM_NAME="$2"; shift; fi
      ;;
    --device) DEVICE=1 ;;
    --run) RUN=1 ;;
    --test) TEST=1 ;;
    --clean) CLEAN=1 ;;
    --screenshot)
      [[ ${2-} != "" ]] || { echo "--screenshot needs a path" >&2; exit 2; }
      SHOT="$2"; shift ;;
    --dark) APPEARANCE=dark ;;
    --light) APPEARANCE=light ;;
    --) shift; APP_ARGS=("$@"); break ;;
    *) echo "unknown option: $1 (use --sim [name], --device, --run, --test, --clean, --screenshot PATH, --dark, --light, -- APP_ARGS)" >&2; exit 2 ;;
  esac
  shift
done

XCODEGEN=/opt/homebrew/bin/xcodegen
[[ -x "$XCODEGEN" ]] || { echo "xcodegen not found at $XCODEGEN" >&2; exit 1; }

PROJ="$ROOT/iOS/Glassine.xcodeproj"
DD="$ROOT/iOS/DerivedData"

echo "==> xcodegen"
"$XCODEGEN" generate --spec "$ROOT/iOS/project.yml" --project "$ROOT/iOS" --quiet

if (( CLEAN )); then
  echo "==> clean"
  rm -rf "$DD"
fi

# Pretty-print the build if xcbeautify is around, otherwise keep only the lines
# that matter. Either way the pipeline must not swallow xcodebuild's exit code.
filter() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify
  else
    grep -E 'error:|warning:|BUILD (SUCCEEDED|FAILED)|\*\* ' || true
  fi
}

if (( DEVICE )); then
  echo "==> build (generic iOS device)"
  set -o pipefail
  xcodebuild -project "$PROJ" -scheme Glassine -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" \
    -quiet build | filter
  APP="$DD/Build/Products/Debug-iphoneos/Glassine.app"
  echo "Built $APP"
  exit 0
fi

# Resolve the simulator UDID by name.
UDID="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
want = sys.argv[1]
data = json.load(sys.stdin)["devices"]
for runtime, devices in data.items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"] == want:
            print(d["udid"])
            raise SystemExit
raise SystemExit("no available iOS simulator named %r" % want)
' "$SIM_NAME")" || { echo "simulator not found: $SIM_NAME" >&2; exit 1; }

echo "==> build (Simulator: $SIM_NAME  $UDID)"
set -o pipefail
xcodebuild -project "$PROJ" -scheme Glassine -configuration Debug \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet build | filter

APP="$DD/Build/Products/Debug-iphonesimulator/Glassine.app"
[[ -d "$APP" ]] || { echo "built app not found at $APP" >&2; exit 1; }
echo "Built $APP"

# The XCUITest bundle. xcodebuild forwards any TEST_RUNNER_-prefixed setting
# into the test runner's environment with the prefix stripped, which is how the
# tests learn which file to open. GLASSINE_DOC is a bare file name inside the
# app's Documents container (the app resolves it there), and something has to
# have copied it in first -- see HANDOFF, "iOS ▸ Testing".
if (( TEST )); then
  echo "==> test (GlassineUITests on $SIM_NAME)"
  DOC="${GLASSINE_DOC:-report.pdf}"
  MD="${GLASSINE_MD:-memo.md}"
  # xcodebuild refuses to overwrite an existing result bundle.
  rm -rf "$DD/TestResults.xcresult"
  xcodebuild -project "$PROJ" -scheme Glassine -configuration Debug \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DD" \
    -resultBundlePath "$DD/TestResults.xcresult" \
    -only-testing:GlassineUITests \
    TEST_RUNNER_GLASSINE_DOC="$DOC" \
    TEST_RUNNER_GLASSINE_MD="$MD" \
    CODE_SIGNING_ALLOWED=NO \
    test | filter
  echo "Result bundle: $DD/TestResults.xcresult"
  exit 0
fi

if [[ -n "$APPEARANCE" || -n "$SHOT" ]] || (( RUN )); then
  if [[ "$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json, sys
u = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["udid"] == u:
            print(d["state"])
' "$UDID")" != "Booted" ]]; then
    echo "==> boot $SIM_NAME"
    xcrun simctl boot "$UDID"
    xcrun simctl bootstatus "$UDID" >/dev/null
  fi
fi

if [[ -n "$APPEARANCE" ]]; then
  xcrun simctl ui "$UDID" appearance "$APPEARANCE" >/dev/null
  echo "Appearance: $APPEARANCE"
fi

if (( RUN )); then
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl terminate "$UDID" com.epps.Glassine >/dev/null 2>&1 || true
  PID="$(xcrun simctl launch "$UDID" com.epps.Glassine "${APP_ARGS[@]}" | awk -F': ' '{print $2}')"
  echo "Launched com.epps.Glassine pid $PID on $UDID"
fi

if [[ -n "$SHOT" ]]; then
  /bin/sleep 2
  mkdir -p "${SHOT:h}"
  xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null
  echo "Screenshot $SHOT"
fi
