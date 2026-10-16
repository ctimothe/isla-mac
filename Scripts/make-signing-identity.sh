#!/bin/bash
# Creates "Isla Code Signing", the fixed self-signed identity that
# Scripts/bundle.sh signs with when no Developer ID is given. Run it once, by
# hand, on the Mac that builds Isla. It is never run by a build or a gate.
#
# Why it exists: an ad-hoc signature's designated requirement is the build's
# own cdhash, so every rebuild and every update is, to macOS, a different app.
# The Accessibility permission the Volume and Brightness pop-up needs was
# granted to the old cdhash, and System Settings went on showing Isla switched
# on while macOS refused the new build. Removing Isla from the list and adding it
# back was the only way out, after every single update (owner, 2026-10-16). A
# certificate's requirement is `identifier "com.ctimothe.isla" and certificate
# leaf = H"…"`, which is the same for every build signed with it, so the
# permission, and Automation consent with it, survives rebuilds and updates.
#
# No trust setting is needed, and none is made. codesign signs with an untrusted
# identity and `codesign --verify --strict` accepts the result; only
# `security find-identity -v` hides it. Checked on 2026-10-16 in a throwaway
# keychain on macOS 27.0.1. An earlier attempt at a local identity was
# abandoned because it asked for a trust setting, an authorization prompt of
# its own; this one does not.
#
# What it changes: one identity (certificate and private key) is added to the
# login keychain, codesign is allowed to use the key, and an encrypted backup is
# written. Gatekeeper treats the app exactly as before: unidentified
# developer, no Team ID. Only a Developer ID changes that.
#
# The backup matters. A release signed with a different certificate is a
# different app to macOS again, so losing this one costs every user one more
# re-grant. Keep the .p12 and its passphrase in a password manager.
set -euo pipefail

NAME="Isla Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP="${1:-$HOME/$NAME.p12}"

fail() { echo "make-signing-identity: $*" >&2; exit 1; }

# Listed without -v on purpose: an untrusted self-signed identity is left out of
# the "valid" list, and that is the only kind this script makes.
if security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$NAME\""; then
    echo "\"$NAME\" is already in the login keychain:"
    security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
    exit 0
fi
[ -t 0 ] || fail "run this in a terminal: it asks for a passphrase for the backup"
[ -e "$BACKUP" ] && fail "a backup already exists at $BACKUP; move it away first"

printf 'Passphrase for the backup file (%s): ' "$BACKUP"
read -rs PASSPHRASE; echo
printf 'Again: '
read -rs AGAIN; echo
[ "$PASSPHRASE" = "$AGAIN" ] || fail "the passphrases differ"
[ "${#PASSPHRASE}" -ge 12 ] || fail "use at least 12 characters"

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/identity.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

# Twenty years. An expired self-signed certificate still satisfies the
# requirement macOS stored, but there is no reason to find out.
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
    -config "$WORK/identity.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null \
    || fail "openssl could not make the certificate"

# Passwords travel in the environment, never on a command line that `ps` shows.
export ISLA_IMPORT_PASS ISLA_BACKUP_PASS
ISLA_IMPORT_PASS="$(/usr/bin/openssl rand -hex 24)"
ISLA_BACKUP_PASS="$PASSPHRASE"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout env:ISLA_IMPORT_PASS -out "$WORK/import.p12" 2>/dev/null \
    || fail "openssl could not package the identity"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -passout env:ISLA_BACKUP_PASS -out "$WORK/backup.p12" 2>/dev/null \
    || fail "openssl could not write the backup"

# -T lets codesign use the key. macOS may still ask once, on the first build,
# whether codesign may use it: answer Always Allow.
security import "$WORK/import.p12" -k "$KEYCHAIN" -P "$ISLA_IMPORT_PASS" -T /usr/bin/codesign >/dev/null \
    || fail "security could not import the identity into the login keychain"

install -m 600 "$WORK/backup.p12" "$BACKUP"

echo "==> \"$NAME\" is in the login keychain:"
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
cat <<EOF

Backup: $BACKUP (encrypted with the passphrase you typed).
  Move it and the passphrase into a password manager, then delete the file.
  To restore on another Mac:
    security import "$NAME.p12" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign

Next: rebuild (bash Scripts/bundle.sh release) and install. macOS sees the
newly signed Isla as a new app one last time: grant Accessibility once more
(remove the old Isla entry from the list first), and it then survives every
later build signed with this identity.
EOF
