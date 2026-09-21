#!/bin/bash
# Единственный гейт, который смотрит на приложение снаружи.
#
# Остальные десять проверяют внутреннюю согласованность: происхождение,
# брендинг, паритет локализаций, идентичность бандла, контракт хелпера,
# состав пакета, его жизненный цикл. Ни один не спрашивает, запустится ли
# скачанная копия. Именно поэтому в релиз ушёл libislamedia.dylib с ad-hoc
# подписью: spctl его отклоняет, /usr/bin/perl отказывается загрузить его
# под карантином, и пользователю предлагают «Move to Trash» — то есть удалить
# медиа-хелпер собственного приложения.
#
# Ad-hoc сборка — законный режим разработки (см. bundle.sh:113), поэтому гейт
# ветвится по DEVELOPER_ID_APPLICATION ровно так же и громко пропускает себя.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/app.noindex/Isla.app}"
DYLIB="$APP/Contents/Resources/libislamedia.dylib"

fail() { echo "!!! $1" >&2; exit 1; }

[ -d "$APP" ] || fail "нет бандла: $APP (сначала ./Scripts/bundle.sh release)"
[ -f "$DYLIB" ] || fail "в бандле нет helper dylib: $DYLIB"

if [ -z "${DEVELOPER_ID_APPLICATION:-}" ]; then
    echo "  ~ DEVELOPER_ID_APPLICATION не задан: ad-hoc сборка."
    echo "  ~ Gatekeeper ЗАБЛОКИРУЕТ такую сборку у пользователя:"
    echo "    dlopen хелпера в /usr/bin/perl будет отклонён системной политикой."
    echo "  ~ Гейт пропущен. release.sh вызывает его после test-package.sh,"
    echo "    где DEVELOPER_ID_APPLICATION уже обязателен, — там он не пропустится."
    exit 0
fi

# Обе части подписи. Вложенный dylib проверяется отдельно, потому что именно
# он ломался: бандл может быть подписан верно, а вложенный код — нет.
for target in "$APP" "$DYLIB"; do
    if ! deep="$(codesign --verify --strict --deep-verify "$target" 2>&1)"; then
        # Понижение проверки — только вслух. --deep-verify — единственная часть,
        # которая заходит во вложенный код, и молчаливый откат на --verify
        # --strict означал, что бандл с непроходящим вложенным кодом — ровно тот
        # случай, ради которого dylib проверяется отдельно, — проходил гейт
        # целиком, не оставив в логе ни строчки.
        echo "  ~ --deep-verify отклонил $target: ${deep%%$'\n'*}"
        echo "  ~ проверка понижена до --verify --strict — вложенный код не проверен"
        codesign --verify --strict "$target" || fail "подпись не проходит проверку: $target"
    fi
    codesign -dvvv "$target" 2>&1 | grep -q "TeamIdentifier=[A-Z0-9]\{10\}" \
        || fail "нет TeamIdentifier — подписано ad-hoc: $target"
done
echo "  ✓ приложение и вложенный dylib подписаны Developer ID"

# Приговор Gatekeeper — единственное, что имеет значение для пользователя.
spctl -a -vvv -t exec "$APP" 2>&1 | grep -q "accepted" \
    || fail "spctl отклоняет приложение — пользователь увидит предупреждение"
echo "  ✓ spctl принимает приложение"

xcrun stapler validate "$APP" >/dev/null 2>&1 \
    || fail "нотаризация не пристёгнута — офлайн-запуск покажет предупреждение"
echo "  ✓ нотаризация пристёгнута к бандлу"

# Карантин — это и есть путь пользователя. Копия помечается так же, как её
# пометил бы Safari, и хелпер обязан загрузиться.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/Isla.app"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$WORK/Isla.app/Contents/Resources/libislamedia.dylib"
OUT="$WORK/out"
/usr/bin/perl -e '
    use DynaLoader;
    # or die — иначе гейт не может упасть. dl_load_file при неудаче возвращает
    # undef, а не умирает, поэтому print выполнялся всегда и grep "loaded" ниже
    # совпадал даже для пути, которого вообще нет: релиз с отклонённым
    # Gatekeeper, битым или отсутствующим dylib проходил проверку, существующую
    # ровно для этого.
    DynaLoader::dl_load_file($ARGV[0], 0x01)
        or die "dl_load_file failed: " . (DynaLoader::dl_error() // "unknown") . "\n";
    print "loaded\n";
' "$WORK/Isla.app/Contents/Resources/libislamedia.dylib" > "$OUT" 2>&1 </dev/null || true
grep -q "loaded" "$OUT" \
    || fail "хелпер под карантином не загрузился — это и есть диалог «Move to Trash»: $(head -1 "$OUT")"
echo "  ✓ helper dylib загружается под карантином"
