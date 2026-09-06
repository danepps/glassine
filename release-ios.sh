#!/bin/zsh
# Cut a Glassine iOS release: set the version, bump the build number, archive,
# export, upload to App Store Connect (which is what TestFlight distributes),
# then commit, tag, push the tag and publish a GitHub release.
#
# Usage: ./release-ios.sh <version> [--check] [--no-upload]
#   ./release-ios.sh 1.0.0
#   ./release-ios.sh 1.0.0 --check       # preflight only: never builds, tags or uploads
#   ./release-ios.sh 1.0.0 --no-upload   # archive + export a local .ipa, touch nothing else
#
# --check exists because of 9.9.9. On 2026-09-05 a "preflight test" of the Mac's
# release.sh with a made-up version went all the way to a public release, and the
# lesson written into HANDOFF is that there is no such thing as a dry run with a
# real-looking version. So: --check stops after the preflight and reports every
# check rather than the first failure, --no-upload builds but writes only into
# build/ios/, and nothing else is safe to try.
#
# The iOS tags are `ios-v<version>`, deliberately separate from the Mac's
# `v<version>`: the two apps ship on their own schedules from one repo, and a
# shared tag would make `git describe` lie about both.
#
# Needs: xcodegen and Xcode's command line tools; the Apple Distribution
# certificate in the login keychain and the App Store provisioning profile
# "Glassine iOS App Store" installed in Xcode's profiles folder (the export signs
# *manually* with those two -- see the comment above the identity checks -- so
# neither can be fetched on the fly); the App Store Connect API key at
# ~/.private_keys/AuthKey_<KEY_ID>.p8, which is where xcodebuild looks and which
# is NOT in the repo and must never be; and `gh` logged in for the GitHub
# release, exactly as on the Mac side.
#
# There is no Sparkle here and no appcast: TestFlight is the feed. Nothing in
# this script touches glassine-appcast.xml or appcast.xml.
set -euo pipefail
ROOT="${0:A:h}"
REPO="danepps/glassine"
TEAM_ID=82H77TF7AH

# App Store Connect API key. The .p8 is referred to by path and never read,
# copied or printed here.
KEY_ID=9D6LK6456Y
ISSUER_ID=69a6de82-678e-47e3-e053-5b8c7c11a4d1
KEY_PATH="$HOME/.private_keys/AuthKey_$KEY_ID.p8"

SPEC="$ROOT/iOS/project.yml"
PROJ="$ROOT/iOS/Glassine.xcodeproj"
XCODEGEN=/opt/homebrew/bin/xcodegen
OUT="$ROOT/build/ios"          # gitignored: .gitignore already has `build/`

# --- Arguments -----------------------------------------------------------
CHECK_ONLY=0
NO_UPLOAD=0
VERSION=""
for argument in "$@"; do
  case "$argument" in
    --check) CHECK_ONLY=1 ;;
    --no-upload) NO_UPLOAD=1 ;;
    -*) echo "unknown option: $argument" >&2; exit 2 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "only one version, got '$VERSION' and '$argument'" >&2
        exit 2
      fi
      VERSION="$argument" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "usage: ${0:t} <version> [--check] [--no-upload]" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]]; then
  echo "version should look like 1.0.0, got: $VERSION" >&2
  exit 1
fi
if (( CHECK_ONLY && NO_UPLOAD )); then
  echo "--check and --no-upload are two different dry runs; pick one" >&2
  exit 2
fi

TAG="ios-v$VERSION"

# --- Preflight -----------------------------------------------------------
# In a real run the first failure stops everything. Under --check every check
# runs and reports, so one pass tells you everything that is not ready -- which
# is the point: a preflight that stops at the first failure has to be run five
# times to learn five things.
FAILURES=0

require() {   # require <ok 0|1> <label> [detail]
  local ok="$1" label="$2" detail="${3:-}"
  if (( ok )); then
    (( CHECK_ONLY )) && printf '  ok    %s\n' "$label"
    return 0
  fi
  if (( CHECK_ONLY )); then
    printf '  FAIL  %s%s\n' "$label" "${detail:+ -- $detail}"
    (( FAILURES += 1 ))
    return 0
  fi
  printf '%s%s\n' "$label" "${detail:+: $detail}" >&2
  exit 1
}

(( CHECK_ONLY )) && echo "==> preflight for Glassine iOS $VERSION (checks only; nothing is built)"

# The git-state checks are about *publishing*. --no-upload publishes nothing, so
# it runs in a dirty tree on a working branch, which is where the work is.
if (( ! NO_UPLOAD )); then
  BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
  require $([[ "$BRANCH" == main ]] && echo 1 || echo 0) \
    "releases are cut from main" "currently on $BRANCH"

  # A fully clean tree, so nothing but this script's own edit lands in the
  # release commit.
  DIRTY="$(git -C "$ROOT" status --porcelain)"
  require $([[ -z "$DIRTY" ]] && echo 1 || echo 0) \
    "working tree is clean" "$(printf '%s' "$DIRTY" | wc -l | tr -d ' ') changed path(s)"

  git -C "$ROOT" fetch -q origin || true
  LOCAL="$(git -C "$ROOT" rev-parse HEAD)"
  REMOTE="$(git -C "$ROOT" rev-parse origin/main 2>/dev/null || echo none)"
  require $([[ "$LOCAL" == "$REMOTE" ]] && echo 1 || echo 0) \
    "local main is in sync with origin/main" "pull or push first"
fi

# MARKETING_VERSION lives in iOS/project.yml, which is the source of truth for
# the generated project; Support/Info.plist only interpolates $(MARKETING_VERSION).
CURRENT="$(awk -F'"' '/^ *MARKETING_VERSION:/ { print $2; exit }' "$SPEC")"
NEWER=0
if [[ -n "$CURRENT" && "$CURRENT" != "$VERSION" \
   && "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" == "$VERSION" ]]; then
  NEWER=1
fi
require $NEWER "version $VERSION is newer than the current $CURRENT" "refusing to go backwards"

if (( ! NO_UPLOAD )); then
  TAG_FREE=1
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 \
     || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    TAG_FREE=0
  fi
  require $TAG_FREE "tag $TAG is free" "it already exists locally or on origin"
fi

require $([[ -x "$XCODEGEN" ]] && echo 1 || echo 0) \
  "xcodegen is installed" "expected at $XCODEGEN (brew install xcodegen)"
require $(command -v xcodebuild >/dev/null 2>&1 && echo 1 || echo 0) \
  "xcodebuild is on PATH" "install Xcode's command line tools"

# Three signing checks, because the first release proved they are different
# questions. *Some* Apple identity means Xcode has an account signed in at all.
# An **Apple Distribution** certificate specifically is what an App Store export
# signs with -- and it cannot be conjured: automatic export signing insists on
# *cloud-managed* certificates, and a --no-upload run on 2026-09-06 came back
# from the portal with
#   403 FORBIDDEN_ERROR ... "You haven't been given access to cloud-managed
#   distribution certificates."
# even with a local Apple Distribution certificate in the keychain. So the two
# ExportOptions plists sign **manually**: the local certificate plus the App
# Store profile "Glassine iOS App Store", created through the App Store Connect
# API against that certificate and installed in Xcode's profiles folder. The
# third check is that the profile is actually there, because -exportArchive
# only says "No profiles for 'com.epps.Glassine' were found" when it is not.
# See HANDOFF, "Releasing to TestFlight".
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
require $([[ -n "$IDENTITIES" && "$IDENTITIES" == *Apple* ]] && echo 1 || echo 0) \
  "an Apple codesigning identity is in the keychain" \
  "none found; open Xcode ▸ Settings ▸ Accounts and sign in"
require $([[ "$IDENTITIES" == *"Apple Distribution"* ]] && echo 1 || echo 0) \
  "an Apple Distribution certificate is in the keychain" \
  "Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates… ▸ + ▸ Apple Distribution"

PROFILE_NAME="Glassine iOS App Store"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
HAVE_PROFILE=0
for profile in "$PROFILE_DIR"/*.mobileprovision(N); do
  if security cms -D -i "$profile" 2>/dev/null | grep -q "<string>$PROFILE_NAME</string>"; then
    HAVE_PROFILE=1
    break
  fi
done
require $HAVE_PROFILE \
  "the App Store profile \"$PROFILE_NAME\" is installed" \
  "download it from developer.apple.com ▸ Certificates, IDs & Profiles ▸ Profiles into $PROFILE_DIR"

require $([[ -f "$KEY_PATH" ]] && echo 1 || echo 0) \
  "App Store Connect API key is present" "expected $KEY_PATH"

# gh is only needed for the GitHub release of the tag, which --no-upload skips.
if (( ! NO_UPLOAD )); then
  require $(gh auth status >/dev/null 2>&1 && echo 1 || echo 0) \
    "gh is logged in" "gh auth login"
fi

if (( CHECK_ONLY )); then
  echo
  if (( FAILURES )); then
    echo "preflight: $FAILURES check(s) failed. Nothing was built, tagged or uploaded."
  else
    echo "preflight OK. Nothing was built, tagged or uploaded."
  fi
  exit 0
fi

# --- Version -------------------------------------------------------------
# MARKETING_VERSION is what people see in TestFlight; CURRENT_PROJECT_VERSION is
# the build number, an integer that only ever goes up -- App Store Connect
# rejects a build whose number it has seen before, for the same marketing
# version or any other.
#
# Both are edited in place in iOS/project.yml with sed. Not PlistBuddy: the
# plist they end up in is generated from this spec, and editing the generated
# side would be overwritten by the next `xcodegen generate`. Under --no-upload
# the edit is reverted on the way out, so a local export leaves the spec exactly
# as it found it.
BUILD_NUMBER=$(( $(awk -F'"' '/^ *CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$SPEC") + 1 ))

if (( NO_UPLOAD )); then
  SPEC_BACKUP="$(mktemp -t glassine-project-yml)"
  cp "$SPEC" "$SPEC_BACKUP"
  restore_spec() { cp "$SPEC_BACKUP" "$SPEC"; rm -f "$SPEC_BACKUP"; }
  trap restore_spec EXIT INT TERM
fi

/usr/bin/sed -i '' \
  -e "s/^\( *MARKETING_VERSION: \).*/\1\"$VERSION\"/" \
  -e "s/^\( *CURRENT_PROJECT_VERSION: \).*/\1\"$BUILD_NUMBER\"/" \
  "$SPEC"
echo "==> Glassine iOS $VERSION (build $BUILD_NUMBER)"

# --- Archive -------------------------------------------------------------
"$XCODEGEN" generate --spec "$SPEC" --project "$ROOT/iOS" --quiet

ARCHIVE="$OUT/Glassine-$VERSION.xcarchive"
mkdir -p "$OUT"
rm -rf "$ARCHIVE"

echo "==> archive"
xcodebuild archive \
  -project "$PROJ" \
  -scheme Glassine \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUT/DerivedData" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  -quiet

# --- Export --------------------------------------------------------------
# Two plists, one difference: `destination`. Both sign the same way (manually,
# with the local Apple Distribution certificate and the App Store profile), so
# the .ipa a --no-upload run leaves in build/ios/ is the one that would have gone
# up. The API key is still passed: the upload half of `destination upload`
# authenticates with it.
if (( NO_UPLOAD )); then
  OPTIONS="$ROOT/iOS/ExportOptions-local.plist"
  echo "==> export (local .ipa; nothing is uploaded)"
else
  OPTIONS="$ROOT/iOS/ExportOptions.plist"
  echo "==> export and upload to App Store Connect"
fi

EXPORT="$OUT/export-$VERSION"
rm -rf "$EXPORT"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID"

if (( NO_UPLOAD )); then
  IPA=( "$EXPORT"/*.ipa(N) )
  if (( ${#IPA} )); then
    mv "${IPA[1]}" "$OUT/Glassine-$VERSION.ipa"
    echo
    echo "Wrote $OUT/Glassine-$VERSION.ipa"
    echo "iOS/project.yml was restored; nothing was committed, tagged or uploaded."
  else
    echo "no .ipa in $EXPORT" >&2
    exit 1
  fi
  exit 0
fi

# --- Publish -------------------------------------------------------------
# The build is already in App Store Connect by this point -- that is the one
# step that cannot be undone, and it is deliberately before the tag so a failure
# here never leaves a tag pointing at nothing. If anything below fails part-way,
# recover with:
#   git -C "$ROOT" tag -d ios-v$VERSION
#   git -C "$ROOT" push origin :refs/tags/ios-v$VERSION
#   gh release delete ios-v$VERSION --repo $REPO --yes      (if it got created)
#   git -C "$ROOT" reset --hard origin/main
# then rerun with the *next* version, not this one: the build number is spent
# either way, and App Store Connect will not take it twice. The uploaded build
# stays in TestFlight; expire it there if it should not go out.
git -C "$ROOT" add "$SPEC"
git -C "$ROOT" commit -m "Release iOS $VERSION (build $BUILD_NUMBER)"
git -C "$ROOT" tag "$TAG"
git -C "$ROOT" push origin "$TAG"

gh release create "$TAG" \
  --repo "$REPO" \
  --title "Glassine for iOS $VERSION" \
  --notes "Glassine $VERSION for iPad and iPhone, build $BUILD_NUMBER, on TestFlight."

git -C "$ROOT" push origin main

echo
echo "Uploaded build $BUILD_NUMBER. It appears in TestFlight once App Store"
echo "Connect finishes processing (a few minutes); the export-compliance"
echo "question is already answered by ITSAppUsesNonExemptEncryption in"
echo "iOS/Support/Info.plist."
echo "Tag: https://github.com/$REPO/releases/tag/$TAG"
