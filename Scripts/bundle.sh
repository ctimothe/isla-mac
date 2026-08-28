#!/bin/bash
# Builds Isla.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Isla.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || true)"
# An existing file with no VERSION= line makes sed succeed with empty output, so
# the `|| echo` fallback never fired: the bundle got empty version keys, and
# dmg.sh's own guard compared "" against "" and passed — shipping a versionless
# app in a file called Isla-.dmg.
if [ -z "$VERSION" ]; then
    echo "Scripts/version has no VERSION= line" >&2
    exit 1
fi

# The app icon is a tracked asset (Resources/AppIcon.icns), copied verbatim into
# the bundle. This script used to generate a placeholder icon into build/ so a
# mid-build write could never dirty the tracked tree after release.sh had checked
# it was clean; with a real, committed icon that indirection is gone. The build
# dir is still created here because the per-build entitlements below live in it.
mkdir -p "$ROOT/build"
ICON="$ROOT/Resources/AppIcon.icns"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Isla"

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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Isla reads the current track and controls Music or Spotify when its primary media route is unavailable.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ ! -f "$ICON" ]; then
    echo "missing app icon: $ICON" >&2
    exit 1
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

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
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -o "$APP/Contents/Resources/libislamedia.dylib" \
    "$ROOT/Sources/IslaMediaHelper/helper.m"

# SwiftPM's release executable still contains local symbols. They add more than
# the entire UI payload to a direct-download bundle and have no runtime value;
# strip before signing, because changing a Mach-O afterwards invalidates it.
echo "==> stripping release symbols"
strip -x "$APP/Contents/MacOS/Isla"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
SIGN_KEYCHAIN=""
KEYCHAIN_ARGS=()
# Ad-hoc is fine here, deliberately.
#
# An earlier version of this script provisioned a self-signed identity so that
# local builds would have a stable signature, because the login keychain
# refuses to recognise a rebuilt ad-hoc app and asks for the password again.
# That was solving the wrong problem: it needed a trust setting, which needs an
# authorization prompt of its own, so it traded a recurring interruption for an
# intrusive one. `TokenStore` removed the reason instead — an unsigned build
# keeps its credentials in an owner-only file rather than in a keychain whose
# ACL it can never satisfy — so nothing about local signing has to be clever.

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
    echo "==> signing: $SIGN_IDENTITY"
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
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
