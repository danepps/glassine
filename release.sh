#!/bin/zsh
# Cut a Glassine release: bump the version, build + notarize, zip, update the
# Sparkle appcast, commit, tag, push, and publish a GitHub release.
#
# Usage: ./release.sh <version> [release notes]
#        ./release.sh --check
#   ./release.sh 1.0.1
#   ./release.sh 1.0.1 "Fixes the sidebar collapsing when a tab is added."
#   ./release.sh --check      # preflight only: never builds, tags, or publishes
#
# There is no other dry run. Any real-looking version goes all the way to a
# public release once the secrets are present (9.9.9 did, once).
#
# Needs, all on this Mac's login keychain: the Developer ID Application
# certificate, the "notary" notarytool profile, and the Sparkle EdDSA private
# key. Also `gh` logged in. The GitHub repo must be public or the release
# asset will not be downloadable by Sparkle.
set -euo pipefail
ROOT="${0:A:h}"
REPO="danepps/glassine"

CHECK_ONLY=0
VERSION="${1:-}"
if [[ "$VERSION" == --check ]]; then
  CHECK_ONLY=1
  VERSION=0.0.1   # placeholder that passes the format check; never used
elif [[ -z "$VERSION" ]]; then
  echo "usage: ${0:t} <version> [release notes]   or   ${0:t} --check" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]]; then
  echo "version should look like 1.0.1, got: $VERSION" >&2
  exit 1
fi
NOTES="${2:-Glassine $VERSION.}"

# --- Preflight -----------------------------------------------------------
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != main ]]; then
  echo "releases are cut from main; currently on $BRANCH" >&2
  exit 1
fi

# A fully clean tree, so nothing but this script's own edits lands in the
# release commit.
DIRTY="$(git -C "$ROOT" status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  echo "working tree is not clean:" >&2
  echo "$DIRTY" >&2
  exit 1
fi

git -C "$ROOT" fetch -q origin
if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/main)" ]]; then
  echo "local main differs from origin/main; pull or push first" >&2
  exit 1
fi

if (( ! CHECK_ONLY )); then
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null \
     || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/v$VERSION" >/dev/null 2>&1; then
    echo "tag v$VERSION already exists" >&2
    exit 1
  fi

  CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Support/Info.plist")"
  if [[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" != "$VERSION" \
     || "$CURRENT" == "$VERSION" ]]; then
    echo "version $VERSION is not newer than the current $CURRENT" >&2
    exit 1
  fi
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not logged in (gh auth login)" >&2
  exit 1
fi
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "no Developer ID Application certificate in the keychain" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
  echo "notarytool profile 'notary' missing or invalid" >&2
  exit 1
fi
# Checked here rather than discovered by generate_appcast after a notarization
# round trip. Never fix this with bare generate_keys; import the existing key
# (HANDOFF.md, "Signing on both Macs").
if ! security find-generic-password -a ed25519 >/dev/null 2>&1; then
  echo "Sparkle EdDSA private key (keychain account 'ed25519') not on this Mac" >&2
  exit 1
fi

GENERATE_APPCAST=( "$ROOT"/.build/artifacts/*/Sparkle/bin/generate_appcast(N) )
if (( ${#GENERATE_APPCAST} == 0 )); then
  echo "generate_appcast not found; run ./build.sh once to resolve Sparkle" >&2
  exit 1
fi

if (( CHECK_ONLY )); then
  echo "preflight OK: on main, clean, in sync with origin, cert + notary profile + Sparkle key present"
  exit 0
fi

# --- Version -------------------------------------------------------------
# CFBundleShortVersionString is what people see; CFBundleVersion is what
# Sparkle compares, so it only ever goes up.
PLIST="$ROOT/Support/Info.plist"
BUILD_NUMBER=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
echo "==> Glassine $VERSION (build $BUILD_NUMBER)"

# --- Build, notarize, archive -------------------------------------------
"$ROOT/build.sh" --notarize

APP="$ROOT/build/Glassine.app"
RELEASES="$ROOT/build/releases"
ZIP="$RELEASES/Glassine-$VERSION.zip"
mkdir -p "$RELEASES"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> $ZIP"

# --- Appcast -------------------------------------------------------------
# generate_appcast writes into the directory it is given and merges with the
# feed already there, so stage a directory holding just the new zip and a copy
# of the live feed. It signs entries with the EdDSA key in the keychain. The
# feed is glassine-appcast.xml, not the default appcast.xml, because the repo
# root also carries Folio's frozen appcast.xml (see HANDOFF.md); -o names it.
STAGE="$ROOT/build/appcast-stage"
FEED="glassine-appcast.xml"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$ZIP" "$STAGE/"
cp "$ROOT/$FEED" "$STAGE/$FEED"
"${GENERATE_APPCAST[1]}" \
  -o "$STAGE/$FEED" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  "$STAGE"
cp "$STAGE/$FEED" "$ROOT/$FEED"
echo "==> $FEED updated"

# --- Publish -------------------------------------------------------------
# If anything below fails part-way, recover with:
#   git -C "$ROOT" tag -d v$VERSION; git -C "$ROOT" push origin :refs/tags/v$VERSION
#   gh release delete v$VERSION --repo $REPO --yes        (if it got created)
#   git -C "$ROOT" reset --hard origin/main
# then rerun. Nothing is live for users until the final push of main.
# Order matters: the feed goes live the moment main is pushed (raw
# githubusercontent), so the release asset must already be downloadable.
# Push only the tag first, publish the release against it, then push main.
git -C "$ROOT" add "$ROOT/Support/Info.plist" "$ROOT/$FEED"
git -C "$ROOT" commit -m "Release v$VERSION"
git -C "$ROOT" tag "v$VERSION"
git -C "$ROOT" push origin "v$VERSION"

# The versioned zip is what the appcast signs and points at. The unversioned
# copy exists so .../releases/latest/download/Glassine.zip is a stable
# direct-download URL for the website.
STABLE_ZIP="$RELEASES/Glassine.zip"
cp "$ZIP" "$STABLE_ZIP"
gh release create "v$VERSION" "$ZIP" "$STABLE_ZIP" \
  --repo "$REPO" \
  --title "Glassine $VERSION" \
  --notes "$NOTES"

git -C "$ROOT" push origin main

echo
echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
