#!/usr/bin/env bash
# ./scripts/source-fresh.sh — is this checkout the Isla that shipped?
#
# Run it before reading this code to describe, design, document or measure the
# app. It answers one question: does HEAD contain everything on origin/main?
#
# It exists because of 2026-10-19. A session read Sources/IslaKit in a worktree
# cut at ed3802e (2026-09-22) and rebuilt the whole island on the canvas from
# it. The shipped app was 852 commits and a redesign further on, and the two
# histories did not even share a root: the app cut that worktree from `origin`,
# which was a local backup bare repo frozen at the old main, while the live main
# was only on the `github` remote. Nothing said so; the code looked plausible.
# Two checks come out of that, and both run here:
#
#   1. origin must be GitHub. A worktree is cut from origin/HEAD, and
#      Scripts/release.sh tags to `origin`, so an origin that is not the live
#      remote is wrong twice over.
#   2. HEAD must contain origin/main. A checkout that shares no history with it,
#      or lacks a commit it has, is not the shipped app — whatever its branch
#      is called.
#
#   ./scripts/source-fresh.sh            fetch, compare, explain
#   ./scripts/source-fresh.sh --quiet    one line; silent exit code for hooks
#   exit 0 fresh · 1 stale or unrelated · 2 origin is not GitHub
#
# No network is not an error: a fetch that fails falls back to the origin/main
# last seen, and says so, because a cached answer is still better than none.

set -uo pipefail

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1
say() { [ "$quiet" = 1 ] || printf '%s\n' "$*"; }

cd "$(git rev-parse --show-toplevel)" || exit 2

expected='ctimothe/isla-mac'
url="$(git remote get-url origin 2>/dev/null || true)"
case "$url" in
  *"$expected"*) ;;
  *)
    echo "WRONG ORIGIN: origin is '${url:-missing}', not GitHub $expected."
    echo "  Fix: git remote rename origin backup && git remote add origin https://github.com/$expected.git && git fetch origin"
    exit 2
    ;;
esac

cached=""
if ! git fetch --quiet origin main 2>/dev/null; then
  cached=" (could not reach GitHub — compared against the origin/main last fetched)"
fi

base="$(git rev-parse --verify --quiet origin/main)" || { echo "NO origin/main: run git fetch origin"; exit 1; }
head="$(git rev-parse HEAD)"
short() { git rev-parse --short "$1"; }
when() { git log -1 --format=%ad --date=short "$1"; }

if ! git merge-base HEAD origin/main >/dev/null 2>&1; then
  echo "UNRELATED: HEAD $(short HEAD) ($(when HEAD)) shares no history with origin/main $(short origin/main) ($(when origin/main)).$cached"
  echo "  This is not the shipped app. Start from it: git worktree add <path> -b <branch> origin/main"
  exit 1
fi

behind="$(git rev-list --count HEAD..origin/main)"
if [ "$behind" -gt 0 ]; then
  echo "STALE: HEAD $(short HEAD) ($(when HEAD)) is $behind commits behind origin/main $(short origin/main) ($(when origin/main)).$cached"
  echo "  Do not describe this checkout as the shipped app. Fix: git merge origin/main, or branch from origin/main."
  exit 1
fi

ahead="$(git rev-list --count origin/main..HEAD)"
say "FRESH: HEAD $(short HEAD) contains origin/main $(short origin/main) ($(when origin/main)); $ahead commit(s) of its own.$cached"
[ "$quiet" = 1 ] && echo "fresh"
exit 0
