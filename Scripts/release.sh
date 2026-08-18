#!/bin/bash
# Explicit publishing path: verify, Developer ID sign, notarize, tag, then upload.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version")"
TAG="v$VERSION"
DMG="$ROOT/build/DynamicIsland-$VERSION.dmg"
NOTES="$ROOT/docs/releases/$VERSION.md"

cd "$ROOT"

fail() { echo "!!! $1" >&2; exit 1; }
require_env() { [ -n "${!1:-}" ] || fail "$1 is required"; }

# A release points at a commit, never at an uncommitted local artifact.
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
[ -s "$NOTES" ] || fail "release notes are required at docs/releases/$VERSION.md"

command -v gh >/dev/null || fail "GitHub CLI is required: brew install gh"
gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated: gh auth login"
command -v xcrun >/dev/null || fail "Xcode command-line tools are required"

require_env DEVELOPER_ID_APPLICATION
require_env APPLE_ID
require_env APPLE_TEAM_ID
require_env APPLE_APP_SPECIFIC_PASSWORD
security find-identity -v -p codesigning | grep -F "$DEVELOPER_ID_APPLICATION" >/dev/null || \
    fail "Developer ID Application identity is not installed in the keychain"

git fetch --quiet origin
[ -z "$(git rev-list @{u}..HEAD 2>/dev/null)" ] || \
    fail "unpushed commits would make the tag unavailable on GitHub"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "tag $TAG already exists; increment Scripts/version"
fi

echo "==> local release gates"
swift test
bash Scripts/test-provenance.sh
bash Scripts/test-branding.sh
bash Scripts/test-localizations.sh
bash Scripts/bundle.sh release
bash Scripts/test-helper.sh
bash Scripts/test-package.sh
bash Scripts/dmg.sh
[ -f "$DMG" ] || fail "disk image was not built: $DMG"

echo "==> sign and notarize $DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG"
xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> tag $TAG"
git tag -a "$TAG" -m "Dynamic Island $VERSION"
git push --quiet origin "$TAG"

echo "==> GitHub release"
REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
PREVIOUS="$(git tag --sort=-v:refname | sed -n 2p)"
GENERATE_ARGS=(-f "tag_name=$TAG")
if [ -n "$PREVIOUS" ]; then
    GENERATE_ARGS+=(-f "previous_tag_name=$PREVIOUS")
fi
GENERATED="$(gh api "repos/$REPO/releases/generate-notes" \
    "${GENERATE_ARGS[@]}" --jq '.body' 2>/dev/null || true)"

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT
cp "$NOTES" "$BODY"
SUM="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
printf '\n\n**SHA-256** `%s`\n\nVerify with `shasum -a 256 DynamicIsland-%s.dmg`.\n' \
    "$SUM" "$VERSION" >> "$BODY"
[ -n "$GENERATED" ] && printf '\n\n---\n\n%s\n' "$GENERATED" >> "$BODY"

gh release create "$TAG" "$DMG" \
    --title "Dynamic Island $VERSION" \
    --notes-file "$BODY" \
    --latest

gh release view "$TAG" --json url --jq '"==> released: " + .url'
