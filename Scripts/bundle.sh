#!/bin/bash
# Builds Isla.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
#
# ISLA_VERSION_OVERRIDE and ISLA_BUILD_OVERRIDE are for Scripts/rehearse-update.sh
# and Scripts/publish-dev-update.sh ONLY: they build the bundle as a later
# version than Scripts/version says — a rehearsal's, or a dev build's four-part
# version for the local update feed. Both must be set together, the version as
# dotted numbers and the build as a whole number. Nothing else sets them; a
# release (Scripts/release.sh) never does, and Scripts/version stays the truth.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
# In a folder whose name ends in .noindex, which Spotlight never indexes: a
# bundle sitting in build/ used to show up in Spotlight and Launchpad beside
# the installed app — three "Isla" results, on 2026-09-21, and a URL callback
# can land in whichever copy LaunchServices prefers. The built app is an
# intermediate; the one people open is the copy Scripts/install.sh puts in
# /Applications. (`.metadata_never_index` was tried first and is ignored.)
APP="$ROOT/build/app.noindex/Isla.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || true)"
# An existing file with no VERSION= line makes sed succeed with empty output, so
# the `|| echo` fallback never fired: the bundle got empty version keys, and
# dmg.sh's own guard compared "" against "" and passed — shipping a versionless
# app in a file called Isla-.dmg.
if [ -z "$VERSION" ]; then
    echo "Scripts/version has no VERSION= line" >&2
    exit 1
fi
BUILD="$(sed -n 's/^BUILD=//p' "$ROOT/Scripts/version" 2>/dev/null || true)"
case "$BUILD" in
    ''|*[!0-9]*) echo "Scripts/version needs BUILD= and a whole number" >&2; exit 1 ;;
esac

# The rehearsal override (see the header): both or neither, and well formed.
if [ -n "${ISLA_VERSION_OVERRIDE:-}" ] || [ -n "${ISLA_BUILD_OVERRIDE:-}" ]; then
    [ -n "${ISLA_VERSION_OVERRIDE:-}" ] && [ -n "${ISLA_BUILD_OVERRIDE:-}" ] || {
        echo "ISLA_VERSION_OVERRIDE and ISLA_BUILD_OVERRIDE must be set together" >&2; exit 1
    }
    case "$ISLA_VERSION_OVERRIDE" in
        ''|*[!0-9.]*|.*|*.|*..*) echo "ISLA_VERSION_OVERRIDE must be dotted numbers, got '$ISLA_VERSION_OVERRIDE'" >&2; exit 1 ;;
    esac
    case "$ISLA_BUILD_OVERRIDE" in
        ''|*[!0-9]*) echo "ISLA_BUILD_OVERRIDE must be a whole number, got '$ISLA_BUILD_OVERRIDE'" >&2; exit 1 ;;
    esac
    VERSION="$ISLA_VERSION_OVERRIDE"
    BUILD="$ISLA_BUILD_OVERRIDE"
    echo "==> REHEARSAL BUILD: version $VERSION build $BUILD (not Scripts/version)" >&2
fi

# The app icon is two tracked assets, copied verbatim into the bundle:
# Resources/Assets.car, the layered Icon Composer icon that macOS 26 draws in
# every appearance (named by CFBundleIconName), and Resources/AppIcon.icns, the
# flattened fallback (named by CFBundleIconFile). Both are compiled from
# Resources/AppIcon.icon by Scripts/make-app-icon.sh, run by hand when the
# icon changes, so a build needs no Xcode. This script used to generate a
# placeholder icon into build/ so a mid-build write could never dirty the
# tracked tree after release.sh had checked it was clean; with a real,
# committed icon that indirection is gone. The build dir is still created here
# because the per-build entitlements below live in it.
mkdir -p "$ROOT/build"
ICON="$ROOT/Resources/AppIcon.icns"
ICON_CATALOG="$ROOT/Resources/Assets.car"

# Universal. The README only ever said "macOS 15 or later", and macOS 15 and
# 26 still run on Intel Macs, which got an app that refused to open. Intel Macs
# have no notch, and Isla draws one for them like for any notchless display.
# Apple Intelligence translation is weak-linked and simply unavailable there.
ARCH_ARGS=(--arch arm64 --arch x86_64)
echo "==> swift build -c $CONFIG (arm64 + x86_64)"
swift build -c "$CONFIG" --package-path "$ROOT" "${ARCH_ARGS[@]}"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" "${ARCH_ARGS[@]}" --show-bin-path)/Isla"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Isla"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Isla</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Isla</string>
    <key>CFBundleIdentifier</key><string>com.ctimothe.isla</string>
    <key>CFBundleExecutable</key><string>Isla</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.ctimothe.isla.oauth</string>
        <key>CFBundleURLSchemes</key><array><string>isla</string></array>
    </dict></array>
    <key>NSServices</key>
    <array><dict>
        <key>NSMenuItem</key>
        <dict><key>default</key><string>Translate in Isla</string></dict>
        <key>NSMessage</key><string>translateSelection</string>
        <key>NSPortName</key><string>Isla</string>
        <key>NSSendTypes</key><array><string>NSStringPboardType</string></array>
    </dict></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Isla asks Music and Spotify for shuffle, repeat and the exact position of the song, and controls them when Now Playing is unavailable.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Isla shows new screenshots and recordings saved to the Desktop and files you put on the Shelf from there, and reads lyrics folders you add there.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Isla shows files you put on the Shelf from Documents, and reads lyrics folders you add there.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Isla shows files you put on the Shelf from Downloads, and reads lyrics folders you add there.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Isla shows files you put on the Shelf from an external disk, and reads lyrics folders you add there.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Isla shows files you put on the Shelf from a network volume, and reads lyrics folders you add there.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

# The public half of the update signing key (Scripts/make-update-key.sh). Update
# Now installs only a disk image signed by its private half, so a build without
# it can still find an update but only offers the download page. Checked here
# rather than trusted: a key that is not 32 bytes of base64 would make every
# update fail its signature check, and that is better found by the build.
UPDATE_KEY_FILE="$ROOT/Resources/update-public-key.txt"
if [ -s "$UPDATE_KEY_FILE" ]; then
    UPDATE_KEY="$(tr -d '[:space:]' < "$UPDATE_KEY_FILE")"
    [ "$(printf '%s' "$UPDATE_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ] || {
        echo "!!! $UPDATE_KEY_FILE is not a 32-byte base64 Ed25519 public key" >&2
        exit 1
    }
    /usr/libexec/PlistBuddy -c "Add :IslaUpdatePublicKey string $UPDATE_KEY" "$APP/Contents/Info.plist" >/dev/null
    echo "==> update key: $UPDATE_KEY"
else
    echo "==> no update key (Resources/update-public-key.txt): Update Now offers only the download page" >&2
fi

for asset in "$ICON" "$ICON_CATALOG"; do
    if [ ! -f "$asset" ]; then
        echo "missing app icon: $asset (rebuild it with Scripts/make-app-icon.sh)" >&2
        exit 1
    fi
done
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_CATALOG" "$APP/Contents/Resources/Assets.car"

echo "==> licenses and notices"
mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/LICENSE"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"

# Таблицы строк кладутся прямо в бандл, а не через ресурсы SwiftPM: бандл здесь
# собирается вручную, и .lproj рядом с исполняемым файлом — то, где их ищет сама
# macOS. Язык она выбирает потом сама, по списку предпочитаемых у пользователя.
echo "==> локализации"
for lproj in "$ROOT"/Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    echo "    $(basename "$lproj")"
done

# Now Playing helper. Built here rather than by SwiftPM because it is not linked
# into the app: it is loaded into /usr/bin/perl at runtime. See helper.m.
echo "==> building Now Playing helper"
clang -dynamiclib -fobjc-arc -O2 \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min=15.0 \
    -framework Foundation -framework ImageIO -framework CoreGraphics \
    -o "$APP/Contents/Resources/libislamedia.dylib" \
    "$ROOT/Sources/IslaMediaHelper/helper.m"

# App Intents: what Shortcuts, Spotlight and Siri read to find Isla's verbs.
#
# Shortcuts does not read the binary. It reads `Metadata.appintents`, a small
# bundle of JSON that Xcode normally produces in a build phase this project does
# not have — there is no Xcode project here, only SwiftPM and this script. The
# generator ships inside Xcode, and it needs two inputs: the module's sources,
# and the "const values" the compiler extracts from the types that conform to
# App Intents protocols.
#
# The const values are extracted here, by one type-check pass with the flags
# spelled out, rather than scavenged from SwiftPM's build directory. That used
# to be a `find` over `.build`, and it only ever worked on one toolchain: Swift
# 6.4's SwiftPM passes `-emit-const-values` and a protocol list by itself when
# a target imports AppIntents, and writes them into its new build layout.
# Xcode 26.6's SwiftPM does neither, so on the CI image the search found
# nothing and the release gate failed with "no .swiftconstvalues found". Asked
# for explicitly, it works on either: `-const-gather-protocols-file` is the
# original frontend spelling, still accepted by 6.4. A type check is about six
# seconds and links nothing.
#
# The protocol list is the fixed set the toolchain gathers for App Intents,
# copied verbatim from what Swift 6.4's SwiftPM writes. The output carries no
# bundle id and no path; it is derived from the compiled Swift, so this is
# equivalent to what Xcode would have produced. It must land *before* the
# signature, because adding a file to a signed bundle invalidates it.
#
# Skipped, loudly but without failing, when only the Command Line Tools are
# installed: the processor ships with full Xcode. `Scripts/test-package.sh` is
# where a release insists on it.
TOOLCHAIN_DIR="$(xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain"
INTENTS_TOOL="$TOOLCHAIN_DIR/usr/bin/appintentsmetadataprocessor"
if [ -x "$INTENTS_TOOL" ]; then
    echo "==> generating App Intents metadata"
    INTENTS_WORK="$ROOT/build/appintents"
    rm -rf "$INTENTS_WORK"
    mkdir -p "$INTENTS_WORK"
    SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
    TRIPLE="$(uname -m)-apple-macosx15.0"
    printf '%s' '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","AppUnionValue","AppUnionValueCasesProviding","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' \
        > "$INTENTS_WORK/protocols.json"
    find "$ROOT/Sources/IslaKit" -name '*.swift' > "$INTENTS_WORK/kit-sources.txt"
    # IslaKit is where the intents live. `-swift-version 5` matches the
    # package's language mode, so the pass sees the code as the build did.
    if swiftc -typecheck -wmo -parse-as-library -swift-version 5 \
        -module-name IslaKit \
        -target "$TRIPLE" \
        -sdk "$SDK_ROOT" \
        -emit-const-values-path "$INTENTS_WORK/IslaKit.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$INTENTS_WORK/protocols.json" \
        @"$INTENTS_WORK/kit-sources.txt" \
        && [ -s "$INTENTS_WORK/IslaKit.swiftconstvalues" ]; then
        find "$ROOT/Sources/Isla" "$ROOT/Sources/IslaKit" -name '*.swift' > "$INTENTS_WORK/sources.txt"
        echo "$INTENTS_WORK/IslaKit.swiftconstvalues" > "$INTENTS_WORK/constvalues.txt"
        "$INTENTS_TOOL" \
            --output "$APP/Contents/Resources" \
            --toolchain-dir "$TOOLCHAIN_DIR" \
            --module-name Isla \
            --sdk-root "$SDK_ROOT" \
            --xcode-version "$(xcodebuild -version 2>/dev/null | sed -n 's/Build version //p')" \
            --platform-family macOS \
            --deployment-target 15.0 \
            --target-triple "$TRIPLE" \
            --source-file-list "$INTENTS_WORK/sources.txt" \
            --swift-const-vals-list "$INTENTS_WORK/constvalues.txt" \
            || echo "!!! App Intents metadata failed — Shortcuts will not see Isla" >&2
    else
        echo "!!! could not extract App Intents const values — Shortcuts will not see Isla" >&2
    fi
else
    echo "==> skipping App Intents metadata (needs full Xcode, not just the CLT)"
fi

# SwiftPM's release executable still contains local symbols. They add more than
# the entire UI payload to a direct-download bundle and have no runtime value;
# strip before signing, because changing a Mach-O afterwards invalidates it.
echo "==> stripping release symbols"
strip -x "$APP/Contents/MacOS/Isla"

SIGN_KEYCHAIN=""
KEYCHAIN_ARGS=()
# The identity, in order: a Developer ID when one is given (releases), then the
# fixed self-signed "Isla Code Signing" identity when this Mac has one, then
# ad-hoc. ISLA_SIGN_ADHOC=1 forces ad-hoc. Not ISLA_ADHOC: release.sh already uses
# that to mean "publish without a Developer ID", and such a release is exactly
# the build that should carry the fixed identity.
#
# Why the middle step (owner, 2026-10-16): an ad-hoc signature's designated
# requirement is the build's cdhash, so to macOS every rebuild and every update
# is a different app. The Accessibility permission the Volume and Brightness
# pop-up needs then stops applying while System Settings still shows Isla
# switched on, and the only way back was to remove Isla from the list and add it
# again, after every update. A certificate's requirement names the certificate,
# not the build, so the permission survives. `Scripts/make-signing-identity.sh`
# makes the identity, once, by hand; nothing here creates one.
#
# An earlier version of this script provisioned a self-signed identity itself
# and was dropped because it needed a trust setting, an authorization prompt of
# its own. This one needs none: codesign signs with an untrusted identity and
# `codesign --verify --strict` accepts it (checked on 2026-10-16). Credentials
# are unaffected: there is still no team, so `TokenStore` keeps the Spotify
# tokens in its owner-only file exactly as it does for an ad-hoc build.
#
# Pinned, not merely named (review, 2026-10-16). Any certificate called "Isla
# Code Signing" would satisfy a name match, and a second one, made after a lost
# backup or on another Mac, is a different designated requirement: every user
# would lose the permission again, which is the one thing this exists to stop.
# Scripts/signing-identity.sha1 holds the SHA-1 of the one certificate releases
# are signed with (make-signing-identity.sh writes it), and only that one is
# used. A same-named certificate with another hash stops the build. Signing is
# by that hash, so codesign can never pick between two by name.
#
# With no pinned identity in the keychain the build is ad-hoc, loudly: fine for
# a clone of the repository or for CI, never for a release, which release.sh
# checks against the pin itself.
LOCAL_IDENTITY_NAME="Isla Code Signing"
PIN_FILE="$ROOT/Scripts/signing-identity.sha1"
PINNED_HASH=""
[ -f "$PIN_FILE" ] && PINNED_HASH="$(tr -d '[:space:]' < "$PIN_FILE" | tr '[:lower:]' '[:upper:]')"
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
elif [ "${ISLA_SIGN_ADHOC:-0}" != "1" ]; then
    # Without -v: an untrusted self-signed identity is left out of the "valid"
    # list, and it is the only kind this looks for.
    LOCAL_HASHES="$(security find-identity -p codesigning 2>/dev/null \
        | grep -F "\"$LOCAL_IDENTITY_NAME\"" | awk '{print $2}' | sort -u || true)"
    if [ -z "$LOCAL_HASHES" ]; then
        SIGN_IDENTITY="-"
        echo "==> no \"$LOCAL_IDENTITY_NAME\" identity on this Mac: signing ad-hoc," >&2
        echo "    so macOS forgets Isla's Accessibility permission on every install." >&2
        echo "    Once per build Mac: bash Scripts/make-signing-identity.sh" >&2
    elif [ -z "$PINNED_HASH" ]; then
        echo "!!! \"$LOCAL_IDENTITY_NAME\" is in the keychain but $PIN_FILE is missing;" >&2
        echo "    rerun Scripts/make-signing-identity.sh to write it, or set ISLA_SIGN_ADHOC=1" >&2
        exit 1
    elif printf '%s\n' "$LOCAL_HASHES" | grep -qx "$PINNED_HASH"; then
        SIGN_IDENTITY="$PINNED_HASH"
    else
        echo "!!! the keychain's \"$LOCAL_IDENTITY_NAME\" is not the pinned certificate:" >&2
        printf '      keychain %s\n' $LOCAL_HASHES >&2
        echo "      pinned   $PINNED_HASH ($PIN_FILE)" >&2
        echo "    Restore the pinned one from its backup; a different certificate makes" >&2
        echo "    every installed Isla lose its permissions. ISLA_SIGN_ADHOC=1 builds anyway." >&2
        exit 1
    fi
else
    SIGN_IDENTITY="-"
fi

# Entitlements are assembled per build, because one of them depends on the
# signing identity. `keychain-access-groups` needs the team prefix — the ten
# characters in parentheses at the end of a Developer ID identity — and an
# ad-hoc signature has no team at all. Claimed without a valid prefix, launchd
# refuses to spawn the app (POSIX 163), so it is added only when there is a
# team to add. With it, the Spotify tokens live in the data-protection
# keychain and macOS never re-prompts for them; without it they fall back to
# the legacy keychain, which prompts once per signature.
ENTITLEMENTS="$ROOT/build/Isla.entitlements"
cp "$ROOT/Resources/Isla.entitlements" "$ENTITLEMENTS"
TEAM_ID="$(printf '%s' "$SIGN_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
if [ -n "$TEAM_ID" ]; then
    echo "==> keychain access group: $TEAM_ID.com.ctimothe.isla"
    /usr/libexec/PlistBuddy \
        -c "Add :keychain-access-groups array" \
        -c "Add :keychain-access-groups:0 string $TEAM_ID.com.ctimothe.isla" \
        "$ENTITLEMENTS" >/dev/null
fi
# Hardened runtime on both paths, and no `--deep` on either. `--deep` is
# deprecated by Apple and signs outside-in, applying the app's flags and
# entitlements to nested code instead of sealing it first; the nested code here
# is the helper dylib, which is exactly what must be signed properly. Signing
# it explicitly, before the bundle, is the supported order. Ad-hoc builds get
# the same runtime protections as release ones, so local testing exercises
# what ships.
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> ad-hoc signing"
    SIGN_ARGS=(
        --force --options runtime
        --entitlements "$ENTITLEMENTS"
        --sign -
    )
else
    if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
        echo "==> signing: $SIGN_IDENTITY"
    else
        echo "==> signing: $LOCAL_IDENTITY_NAME ($SIGN_IDENTITY)"
    fi
    # `--timestamp` only for a real Developer ID. A self-signed local identity
    # has no business contacting Apple's timestamp server, and the request
    # fails the build when it cannot.
    TIMESTAMP_ARGS=()
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && TIMESTAMP_ARGS=(--timestamp)
    SIGN_ARGS=(
        --force --options runtime
        "${TIMESTAMP_ARGS[@]+"${TIMESTAMP_ARGS[@]}"}"
        "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}"
        --entitlements "$ENTITLEMENTS"
        --sign "$SIGN_IDENTITY"
    )
fi
# Расширенные атрибуты снимаются первыми. iCloud вешает на файлы
# com.apple.FinderInfo, а codesign отказывается подписывать что-либо с ним —
# «resource fork, Finder information, or similar detritus not allowed». Папка
# «Рабочий стол» синхронизируется с iCloud у многих по умолчанию, так что клон
# репозитория там перестает подписываться, стоило его туда перенести.
xattr -cr "$APP"

# Ошибка не глушится и не понижается до предупреждения. Раньше отказ печатал
# мягкую строку и возвращал ноль: скрипт доходил до «done», а в build лежал
# бандл, про который codesign говорит «code object is not signed at all».
# Заметить это можно было только по возвращающимся запросам TCC — то есть у
# того, кто уже поставил приложение.
# Inside-out: the nested helper dylib is sealed first, then the bundle around
# it. This is what `--deep` used to paper over, badly.
if [ -f "$APP/Contents/Resources/libislamedia.dylib" ]; then
    # The same flags the bundle gets, `--timestamp` included. Apple requires a
    # secure timestamp on every executable in a notarized submission, and
    # `--deep` used to propagate the outer flags for us — signing the nested
    # code explicitly means stating them explicitly.
    NESTED_ARGS=(--force --options runtime)
    [ -n "${DEVELOPER_ID_APPLICATION:-}" ] && NESTED_ARGS+=(--timestamp)
    [ -n "$SIGN_KEYCHAIN" ] && NESTED_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    codesign "${NESTED_ARGS[@]}" --sign "$SIGN_IDENTITY" \
        "$APP/Contents/Resources/libislamedia.dylib" || {
        echo "!!! codesign не смог подписать helper dylib — см. вывод выше" >&2
        exit 1
    }
fi
codesign "${SIGN_ARGS[@]}" "$APP" || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    if [ "$SIGN_IDENTITY" != "-" ] && [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
        # The usual causes with the local identity: the login keychain is
        # locked (an SSH session), or codesign was refused the key at its
        # first-use prompt. errSecInternalComponent is how both look.
        echo "    with \"$LOCAL_IDENTITY_NAME\": unlock the login keychain and answer" >&2
        echo "    codesign's prompt with Always Allow, or build ad-hoc: ISLA_SIGN_ADHOC=1." >&2
        echo "    \"ambiguous\" means the same identity is in two keychains; delete one." >&2
    fi
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
