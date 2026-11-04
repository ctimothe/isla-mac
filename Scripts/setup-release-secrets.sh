#!/bin/bash
# Gives the release workflow (.github/workflows/release.yml) what it signs with.
# The owner runs it once, by hand, on the Mac that holds the keys; an agent
# never does, because it hands Isla's signing keys to GitHub.
#
#   bash Scripts/setup-release-secrets.sh                # Isla's own certificate and update key
#   bash Scripts/setup-release-secrets.sh --developer-id # later: the Developer ID as well
#
# What it does, and nothing more:
#   1. Creates the "release" environment on ctimothe/isla-mac, usable only from
#      main, so a pull request (and a fork's above all) can never read it.
#   2. Stores three environment secrets, each piped from where it lives straight
#      into `gh secret set`, so no value is printed or put on a command line:
#        ISLA_UPDATE_SIGNING_KEY    from the login keychain ("Isla Update Signing")
#        ISLA_SIGNING_P12_BASE64    "Isla Code Signing", exported fresh from the
#                                   login keychain (Scripts/export-signing-identity.swift)
#        ISLA_SIGNING_P12_PASSWORD  the random passphrase that export was made with
#      Nothing is typed. It used to ask for the passphrase of the backup
#      make-signing-identity.sh wrote, and on 2026-11-04 nobody had it: the
#      keychain holds the same certificate and key, so it is the source now.
#      macOS asks twice to allow reading the keychain: type the Mac's password
#      and click Allow (or Always Allow).
#   3. With --developer-id: DEVELOPER_ID_P12_BASE64 from the .p12 named by
#      $DEVELOPER_ID_P12, and its passphrase, the identity's full name, the Apple
#      ID, the team ID and an app-specific password, each typed at the prompt.
#      From the next merge on, releases are notarized and need no xattr step.
#
# These keys are what makes every installed Isla trust an update. Keep the
# password-manager copies regardless: GitHub cannot give a secret back.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="ctimothe/isla-mac"
ENVIRONMENT="release"

fail() { echo "setup-release-secrets: $*" >&2; exit 1; }
command -v gh >/dev/null || fail "GitHub CLI is required: brew install gh"
[ "$(gh api user --jq .login)" = ctimothe ] || fail "gh is not signed in as ctimothe (gh auth switch --user ctimothe)"

echo "==> environment \"$ENVIRONMENT\", main only"
gh api -X PUT "repos/$REPO/environments/$ENVIRONMENT" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
if ! gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
    --jq '.branch_policies[].name' | grep -qx main; then
    gh api -X POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
        -f name=main -f type=branch >/dev/null
fi

set_secret() { gh secret set "$1" --repo "$REPO" --env "$ENVIRONMENT"; }

if [ "${1:-}" != "--developer-id" ]; then
    security find-generic-password -s "Isla Update Signing" -a ed25519 >/dev/null 2>&1 \
        || fail "the update key is not in the login keychain; restore it from the password manager first"
    PIN="$(tr -d '[:space:]' < "$ROOT/Scripts/signing-identity.sha1")"
    WORK="$(mktemp -d)"
    chmod 700 "$WORK"
    trap 'rm -rf "$WORK"' EXIT
    # Random, made for this one export, and stored only in GitHub: the keychain
    # can make another whenever this runs again. It reaches the export in the
    # environment and gh on stdin, never a command line.
    export ISLA_EXPORT_PASS
    ISLA_EXPORT_PASS="$(/usr/bin/openssl rand -base64 32 | tr -d '[:space:]')"
    echo "==> \"Isla Code Signing\" ($PIN) out of the keychain: if macOS asks, type your Mac password and click Allow"
    swift -suppress-warnings "$ROOT/Scripts/export-signing-identity.swift" "$PIN" "$WORK/identity.p12"
    # Opened here with the same passphrase before GitHub sees it, so a bad
    # export fails on this Mac, not in the release job.
    GOT="$(/usr/bin/openssl pkcs12 -in "$WORK/identity.p12" -nokeys -passin env:ISLA_EXPORT_PASS 2>/dev/null \
        | /usr/bin/openssl x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]')"
    [ "$GOT" = "$PIN" ] || fail "the export does not open with its passphrase, or holds another certificate; nothing was stored"
    echo "==> ISLA_UPDATE_SIGNING_KEY (if macOS asks, type your Mac password and click Allow)"
    security find-generic-password -s "Isla Update Signing" -a ed25519 -w | tr -d '[:space:]' | set_secret ISLA_UPDATE_SIGNING_KEY
    echo "==> ISLA_SIGNING_P12_BASE64"
    base64 -i "$WORK/identity.p12" | tr -d '[:space:]' | set_secret ISLA_SIGNING_P12_BASE64
    echo "==> ISLA_SIGNING_P12_PASSWORD"
    printf '%s' "$ISLA_EXPORT_PASS" | set_secret ISLA_SIGNING_P12_PASSWORD
else
    DEV_P12="${DEVELOPER_ID_P12:-}"
    [ -s "$DEV_P12" ] || fail "set DEVELOPER_ID_P12 to the exported Developer ID Application .p12"
    echo "==> DEVELOPER_ID_P12_BASE64"
    base64 -i "$DEV_P12" | tr -d '[:space:]' | set_secret DEVELOPER_ID_P12_BASE64
    for name in DEVELOPER_ID_P12_PASSWORD DEVELOPER_ID_APPLICATION APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD; do
        echo "==> $name"
        set_secret "$name"
    done
fi

echo "==> stored; the next merge to main that changes the app is released"
gh secret list --repo "$REPO" --env "$ENVIRONMENT"
