#!/bin/bash
# Holds Scripts/next-release.sh to its rules in a scratch repository, so the
# release workflow cannot ship a version that goes backwards, release a
# docs-only merge, or put the wrong line on the island (plan
# 2026-10-20-updates-for-everyone). Nothing here touches this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/isla-next-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

failures=0
check() { # description, expected, actual
    if [ "$2" = "$3" ]; then echo "  ✓ $1"; else echo "  ✗ $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}
field() { sed -n "s/^$1=//p"; }

cd "$WORK"
git init -q -b main .
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config tag.gpgsign false
mkdir -p Scripts Sources docs/releases
cp "$ROOT/Scripts/next-release.sh" Scripts/
printf 'VERSION=0.3.0\nBUILD=3\n' > Scripts/version
echo one > Sources/a.swift
git add -A && git commit -qm "feat: the first thing"

out="$(bash Scripts/next-release.sh)"
check "with no tag, Scripts/version is the release" "yes 0.3.0 3" "$(field release <<<"$out") $(field version <<<"$out") $(field build <<<"$out")"

git tag -a v0.3.0 -m v0.3.0
echo words > README.md
git add -A && git commit -qm "docs: a readme"
check "a docs-only change since the tag is not a release" "no" "$(bash Scripts/next-release.sh | field release)"
echo "MIT" > LICENSE
git add -A && git commit -qm "docs: licence year"
check "a licence change ships in the bundle, so it is a release" "yes" "$(bash Scripts/next-release.sh | field release)"
git reset -q --hard HEAD~1

echo two > Sources/a.swift
git add -A && git commit -qm "fix: the island keeps its line"
echo three > Sources/a.swift
git add -A && git commit -qm "chore: tidy"
echo four > Sources/a.swift
git add -A && git commit -qm "feat(shelf): drop files faster"
out="$(bash Scripts/next-release.sh)"
check "an app change after v0.3.0 is 0.3.1, build 4" "yes 0.3.1 4" "$(field release <<<"$out") $(field version <<<"$out") $(field build <<<"$out")"
check "without --write nothing is changed" "" "$(git status --porcelain)"

ISLA_ADHOC=1 bash Scripts/next-release.sh --write >/dev/null
check "--write sets VERSION" "0.3.1" "$(sed -n 's/^VERSION=//p' Scripts/version)"
check "--write sets BUILD" "4" "$(sed -n 's/^BUILD=//p' Scripts/version)"
NOTES=docs/releases/0.3.1.md
first_prose="$(grep -v '^#' "$NOTES" | grep -v '^$' | head -1)"
check "the notes' first prose line is the newest change" "- Drop files faster" "$first_prose"
check "the fix is listed" "1" "$(grep -c '^- The island keeps its line$' "$NOTES")"
check "a chore is not listed" "0" "$(grep -c 'Tidy' "$NOTES" || true)"
check "an ad-hoc release carries the xattr step" "1" "$(grep -c 'xattr -dr com.apple.quarantine' "$NOTES")"
check "the marker is the last line" "1" "$(tail -1 "$NOTES" | grep -c 'written by Scripts/next-release.sh')"

# A retry after a failed release: the version and build hold, and made notes
# are made again with what has been merged since.
git add -A && git commit -qm "chore: release 0.3.1"
echo five > Sources/a.swift
git add -A && git commit -qm "fix: lyrics keep up"
out="$(bash Scripts/next-release.sh --write)"
check "a retry keeps 0.3.1 and build 4" "0.3.1 4" "$(field version <<<"$out") $(field build <<<"$out")"
check "made notes are made again" "1" "$(grep -c '^- Lyrics keep up$' "$NOTES")"
check "a Developer ID release has no xattr step" "0" "$(grep -c 'xattr' "$NOTES" || true)"

printf 'Hand-written notes.\n' > "$NOTES"
bash Scripts/next-release.sh --write >/dev/null
check "a person's notes are kept" "Hand-written notes." "$(cat "$NOTES")"
git add -A && git commit -qm "chore: release 0.3.1"
git tag -a v0.3.1 -m v0.3.1

# A person picks the next minor version in a pull request.
printf 'VERSION=0.4.0\nBUILD=4\n' > Scripts/version
echo six > Sources/a.swift
git add -A && git commit -qm "feat: a bigger thing"
out="$(bash Scripts/next-release.sh)"
check "an untagged, higher VERSION is taken" "0.4.0 5" "$(field version <<<"$out") $(field build <<<"$out")"

# A BUILD a person raised past every tag is kept.
printf 'VERSION=0.4.0\nBUILD=40\n' > Scripts/version
git add -A && git commit -qm "chore: raise the build"
check "a BUILD above every tag is kept" "40" "$(bash Scripts/next-release.sh | field build)"

# A lower VERSION in the file never goes backwards.
printf 'VERSION=0.2.0\nBUILD=1\n' > Scripts/version
git add -A && git commit -qm "chore: an old version file"
out="$(bash Scripts/next-release.sh)"
check "a lower VERSION in the file is passed over" "0.3.2 5" "$(field version <<<"$out") $(field build <<<"$out")"

if [ "$failures" -gt 0 ]; then
    echo "!!! next-release: $failures check(s) failed" >&2
    exit 1
fi
echo "  ✓ next-release holds its rules"
