#!/bin/bash
# Creates the Ed25519 key pair that Isla's in-app update trusts. Run it once,
# by hand, on the Mac that publishes releases. It is never run by a build or a
# gate.
#
# What each half does:
#   - The private key goes into the login keychain as a generic password
#     (service "Isla Update Signing", account "ed25519"). Scripts/release.sh
#     reads it there to sign each release's disk image. Nobody else ever needs it.
#   - The public key goes to Resources/update-public-key.txt, which is committed.
#     Scripts/bundle.sh puts it into Info.plist, and Update Now installs only a
#     disk image whose signature it accepts.
#
# Why a key of Isla's own, and not Apple's: without a Developer ID there is no
# Apple identity to check a download against. This is the scheme Sparkle uses
# (EdDSA over the archive), with CryptoKit in place of a framework. A release
# signed with a different key is refused by every installed copy, so losing the
# private key means users update by hand once. Keep it in a password manager.
#
# The private key is never printed, written to a file or passed on a command
# line: Scripts/update-signing.swift generates it and stores it in one process.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="Isla Update Signing"
ACCOUNT="ed25519"
PUBLIC="$ROOT/Resources/update-public-key.txt"

fail() { echo "make-update-key: $*" >&2; exit 1; }

if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
    echo "The update signing key is already in the login keychain."
    [ -s "$PUBLIC" ] && echo "Its public half: $(cat "$PUBLIC")"
    exit 0
fi
[ -e "$PUBLIC" ] && fail "$PUBLIC exists but the keychain has no private key; restore the key from your backup rather than making a new one"

# The tool stores the private half in the keychain itself, so the key never
# crosses this shell or a command line.
swift "$ROOT/Scripts/update-signing.swift" create-key "$PUBLIC" >/dev/null \
    || fail "could not create the key"
echo "==> private key: login keychain, \"$SERVICE\" / $ACCOUNT"
echo "==> public key:  $PUBLIC ($(cat "$PUBLIC"))"
cat <<EOF

Back up the private key now. Copy it into a password manager with:
  security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w | pbcopy
then clear the clipboard. To restore it on another Mac:
  security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w
  (it asks for the key; paste it)

Commit Resources/update-public-key.txt. Every build after that offers Update Now.
EOF
