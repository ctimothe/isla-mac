#!/bin/bash
# Packs the built app into a disk image — the form a Mac app is handed over in.
# Собирает приложение, если его еще нет, и кладет рядом ярлык /Applications,
# чтобы установка была одним перетаскиванием.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Cyclop.app"
VERSION="$(sed -n 's/^VERSION=//p' "$ROOT/Scripts/version" 2>/dev/null || echo 0.1.0)"
DMG="$ROOT/build/Cyclop-$VERSION.dmg"

# Всегда, а не только когда приложения нет. Иначе образ уносит то, что лежало в
# build с прошлого раза: номер на образе новый, приложение внутри старое, и
# заметить это можно лишь запустив его.
"$ROOT/Scripts/bundle.sh" release

echo "==> раскладка образа"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Cyclop.app"
ln -s /Applications "$STAGE/Applications"

echo "==> сборка $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "Cyclop $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> готово: $DMG ($SIZE)"

# Имя образа обещает версию, и обещание стоит проверить: расходятся они молча.
INSIDE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
if [ "$INSIDE" != "$VERSION" ]; then
    echo "!!! в образе лежит версия $INSIDE, а имя обещает $VERSION" >&2
    exit 1
fi
echo "==> версия внутри совпадает: $INSIDE"

# Сказано здесь, потому что узнать это иначе можно только от человека, у
# которого приложение не открылось.
if ! spctl -a "$APP" >/dev/null 2>&1; then
    cat <<'NOTE'

    Внимание: сборка подписана ad-hoc, без Developer ID, и не нотаризована.
    На твоей машине она запускается, на любой другой Gatekeeper ее не пустит.
    Тому, кому отдаешь образ, придется один раз зайти в Системные настройки →
    Конфиденциальность и безопасность → "Все равно открыть". В macOS 15
    открытие через Control-клик для такого случая больше не работает.

    Чтобы этого не требовалось, нужен Apple Developer ID и нотаризация.
NOTE
fi
