#!/bin/bash
# Builds Dynamic Island.app without Xcode: SwiftPM produces the binary, this script
# assembles the bundle around it and ad-hoc signs it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Dynamic Island.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"

echo "==> generating original app icon"
swift "$ROOT/Scripts/make-icon.swift" "$ROOT/Resources/AppIcon.icns"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/DynamicIsland"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DynamicIsland"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Dynamic Island</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>ru</string></array>
    <key>CFBundleDisplayName</key><string>Dynamic Island</string>
    <key>CFBundleIdentifier</key><string>dev.dynamicisland.app</string>
    <key>CFBundleExecutable</key><string>DynamicIsland</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSServices</key>
    <array><dict>
        <key>NSMenuItem</key>
        <dict><key>default</key><string>Translate in Dynamic Island</string></dict>
        <key>NSMessage</key><string>translateSelection</string>
        <key>NSPortName</key><string>Dynamic Island</string>
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
    <string>Dynamic Island reads the current track and controls Music or Spotify when its primary media route is unavailable.</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

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
    -o "$APP/Contents/Resources/libdynamicislandmedia.dylib" \
    "$ROOT/Sources/DynamicIslandMediaHelper/helper.m"

# SwiftPM's release executable still contains local symbols. They add more than
# the entire UI payload to a direct-download bundle and have no runtime value;
# strip before signing, because changing a Mach-O afterwards invalidates it.
echo "==> stripping release symbols"
strip -x "$APP/Contents/MacOS/DynamicIsland"

SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> ad-hoc signing"
    SIGN_ARGS=(--force --deep --entitlements "$ROOT/Resources/DynamicIsland.entitlements" --sign -)
else
    echo "==> Developer ID signing: $SIGN_IDENTITY"
    SIGN_ARGS=(
        --force --deep --options runtime --timestamp
        --entitlements "$ROOT/Resources/DynamicIsland.entitlements"
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
codesign "${SIGN_ARGS[@]}" "$APP" || {
    echo "!!! codesign не смог подписать бандл — см. вывод выше" >&2
    exit 1
}
codesign --verify --strict "$APP" || {
    echo "!!! подпись не прошла проверку" >&2
    exit 1
}

echo "==> done: $APP"
