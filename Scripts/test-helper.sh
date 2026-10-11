#!/bin/bash
# Проверяет одно: что Now Playing helper отвечает.
#
# Не что он отдаёт верный трек — на машине сборки ничего не играет, да и на живой
# может не играть. Проверяется контракт: получив "get", хелпер обязан выдать одну
# строку валидного JSON. Либо снимок, либо честную ошибку, если маршрут закрыт.
# Молчание — единственный неприемлемый ответ.
#
# Это ловит класс отказов, который не видит ни компилятор, ни подпись, ни проверка
# файлов в бандле: хелпер жив, процесс не падает, а строк не приходит. Так уже
# было — вызов за списком команд, вложенный в колбэк на той же последовательной
# очереди, не возвращал ответ, и вкладка «Музыка» становилась мёртвой в релизе,
# пройдя всю сборку зелёной.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DYLIB="${1:-$ROOT/build/app.noindex/Isla.app/Contents/Resources/libislamedia.dylib}"
TIMEOUT="${TIMEOUT:-8}"

fail() { echo "!!! $1" >&2; exit 1; }

# --- Модульный блок -----------------------------------------------------------
#
# Живая проверка ниже не может воспроизвести то, ради чего этот блок написан: на
# машине сборки нет записи Now Playing. А отказы именно в записи. Прямой эфир в
# браузере отдаёт длительность +Inf, NSJSONSerialization на этом бросает
# исключение, и хелпер падал на каждой публикации — после трёх перезапусков весь
# браузерный звук уходил с острова до конца сеанса. И команда, пришедшая, пока
# хелпер ещё стартует, молча терялась: иконка паузы переключалась и через
# полторы секунды возвращалась обратно.
#
# Поэтому helper.m собирается целиком в обычный исполняемый драйвер
# (Tests/IslaMediaHelperUnit/main.m) с -DISLA_HELPER_UNIT, без конструктора.
# Драйвер не открывает MediaRemote, ничего не грузит в perl и не трогает
# приложения: функции MediaRemote заменены заглушками, отвечающими из фикстуры.
# Только этот блок: HELPER_UNIT_ONLY=1 bash Scripts/test-helper.sh.
UNIT="$(mktemp -d)"
trap 'rm -rf "$UNIT"' EXIT
clang -fobjc-arc -DISLA_HELPER_UNIT -mmacosx-version-min=15.0 \
    -framework Foundation -framework ImageIO -framework CoreGraphics \
    -o "$UNIT/helper-unit" "$ROOT/Tests/IslaMediaHelperUnit/main.m" \
    || fail "модульный драйвер хелпера не собрался"

# Запускает один случай с потолком в 6 с: зависший драйвер — тоже провал, а не
# вечный прогон. Печатает код выхода; вывод драйвера — в $UNIT/<случай>.out.
run_case() {
    local name="$1"; shift
    "$UNIT/helper-unit" "$@" > "$UNIT/$name.out" 2> "$UNIT/$name.err" &
    local pid=$!
    for _ in $(seq 1 60); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        echo 124
        return
    fi
    local status=0
    wait "$pid" || status=$?
    echo "$status"
}

for name in nonfinite invalid early-command; do
    status="$(run_case "$name" "$name")"
    [ "$status" = 0 ] || fail "случай $name: драйвер завершился с кодом $status (134 — неперехваченное исключение) $(head -c 400 "$UNIT/$name.err")"
done
status="$(run_case artwork artwork "$UNIT/cover-big.png")"
[ "$status" = 0 ] || fail "случай artwork: драйвер завершился с кодом $status $(head -c 400 "$UNIT/artwork.err")"
status="$(run_case artwork-small artwork-small "$UNIT/cover-small.png")"
[ "$status" = 0 ] || fail "случай artwork-small: драйвер завершился с кодом $status $(head -c 400 "$UNIT/artwork-small.err")"

python3 - "$UNIT" <<'PY' || fail "модульный блок хелпера не прошёл"
import base64, json, os, subprocess, sys

unit = sys.argv[1]

def lines(name):
    out = []
    for raw in open(os.path.join(unit, name + ".out"), encoding="utf-8", errors="replace"):
        raw = raw.strip()
        if raw:
            out.append(json.loads(raw))
    return out

def check(ok, message):
    if not ok:
        print("!!! " + message, file=sys.stderr)
        sys.exit(1)

# 1. Нечисловые длительность, позиция, скорость и отметка времени уходят нулями,
#    одной строкой, а не обрывом процесса.
got = lines("nonfinite")
check(len(got) == 1, f"nonfinite: ждали одну строку JSON, пришло {len(got)}")
snap = got[0]
for key in ("duration", "elapsed", "rate", "timestamp"):
    check(snap.get(key) == 0, f"nonfinite: {key} должен быть 0, пришло {snap.get(key)!r}")
check(snap.get("title") == "Live radio", f"nonfinite: потерян заголовок: {snap!r}")
print("  ✓ запись с NaN и ±Inf ушла одной строкой с нулями")

# 2. Непереводимая в JSON полезная нагрузка стоит одной строки, но не процесса:
#    следующая за ней уходит как обычно.
got = lines("invalid")
check(got == [{"ok": True}], f"invalid: ждали только {{\"ok\": true}}, пришло {got!r}")
print("  ✓ непереводимая запись пропущена, хелпер жив")

# 3. `get`, записанный до готовности ленты, получает ответ после неё.
got = lines("early-command")
check(len(got) == 1 and got[0].get("title") == "Live radio",
      f"early-command: ждали один снимок в ответ на ранний get, пришло {got!r}")
print("  ✓ команда, пришедшая во время запуска, выполнена после готовности")

# 4. Обложка больше 4 МБ уменьшается до 600 px по длинной стороне и проходит под
#    потолок приложения; маленькая уходит байт в байт.
def pixels(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path],
                         capture_output=True, text=True, check=True).stdout
    values = {}
    for row in out.splitlines():
        row = row.strip()
        if row.startswith("pixel"):
            key, value = row.split(":")
            values[key] = int(value)
    return values["pixelWidth"], values["pixelHeight"]

cap = 4 * 1024 * 1024
big = os.path.join(unit, "cover-big.png")
check(os.path.getsize(big) > cap, f"artwork: фикстура должна превышать 4 МБ, а весит {os.path.getsize(big)}")
got = lines("artwork")
check(len(got) == 1 and "artwork" in got[0], f"artwork: в снимке нет обложки: {[sorted(g) for g in got]!r}")
sent = base64.b64decode(got[0]["artwork"])
check(len(sent) <= cap, f"artwork: обложка {len(sent)} байт не проходит потолок приложения")
sent_path = os.path.join(unit, "cover-sent")
open(sent_path, "wb").write(sent)
w, h = pixels(sent_path)
check(max(w, h) <= 600, f"artwork: обложка {w}x{h}, ждали не больше 600 px")
print(f"  ✓ обложка {os.path.getsize(big)} байт ушла как {w}x{h}, {len(sent)} байт")

small = open(os.path.join(unit, "cover-small.png"), "rb").read()
got = lines("artwork-small")
check(len(got) == 1 and base64.b64decode(got[0].get("artwork", "")) == small,
      "artwork-small: маленькая обложка должна уйти без перекодирования")
print("  ✓ обложка до 600 px ушла без изменений")
PY

if [ "${HELPER_UNIT_ONLY:-0}" = 1 ]; then
    exit 0
fi
rm -rf "$UNIT"

# --- Живой блок ---------------------------------------------------------------

[ -f "$DYLIB" ] || fail "нет хелпера: $DYLIB (сначала ./Scripts/bundle.sh)"
[ -x /usr/bin/perl ] || fail "нет /usr/bin/perl — хелперу негде запускаться"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${HOLDER_PID:-}" ] && kill "$HOLDER_PID" 2>/dev/null; [ -n "${PERL_PID:-}" ] && kill "$PERL_PID" 2>/dev/null' EXIT

FIFO="$WORK/in"
CLOSE="$WORK/close"
OUT="$WORK/out"
mkfifo "$FIFO" "$CLOSE"

# Держатель stdin посылает одну команду и держит канал открытым весь допустимый
# срок. Закрыть его просит основной поток только после проверки ответа: холодный
# MediaRemote иногда отвечает дольше секунды, и прежний таймер сам убивал
# корректный хелпер до истечения заявленного TIMEOUT.
# `art` перед `get`: он сбрасывает запомненный идентификатор обложки, так что
# следующий снимок обязан нести artwork заново. Это и есть контракт, из-за
# которого обложка переставала возвращаться: хелпер считал её уже отданной.
( exec 3>"$FIFO"; echo "art" >&3; echo "get" >&3; read -r _ < "$CLOSE"; exec 3>&- ) &
HOLDER_PID=$!

/usr/bin/perl -e '
    use DynaLoader;
    DynaLoader::dl_load_file($ARGV[0], 0x01);
    while (1) { sleep 3600; }
' "$DYLIB" < "$FIFO" > "$OUT" 2>&1 &
PERL_PID=$!

# Ждём первую строку, а не весь таймаут: хелпер обычно отвечает за десятки
# миллисекунд, и растягивать зелёный прогон на восемь секунд незачем.
for _ in $(seq 1 $((TIMEOUT * 10))); do
    [ -s "$OUT" ] && break
    sleep 0.1
done

[ -s "$OUT" ] || fail "хелпер не ответил ни одной строкой за ${TIMEOUT}с — лента молчит"

python3 - "$OUT" <<'PY'
import json, sys

line = None
for raw in open(sys.argv[1], encoding="utf-8", errors="replace"):
    raw = raw.strip()
    if raw.startswith("{"):
        line = raw
        break

if line is None:
    print("!!! в выводе нет ни одной строки JSON:", file=sys.stderr)
    print(open(sys.argv[1]).read()[:400], file=sys.stderr)
    sys.exit(1)

try:
    payload = json.loads(line)
except json.JSONDecodeError as e:
    print(f"!!! строка не разбирается как JSON: {e}", file=sys.stderr)
    print(line[:400], file=sys.stderr)
    sys.exit(1)

# Закрытый маршрут — тоже ответ. Приложение на него рассчитывает: получив error,
# оно гасит хелпер и уходит на запасной путь.
if "error" in payload:
    print(f"  ✓ хелпер ответил честной ошибкой: {payload['error']}")
    sys.exit(0)

required = {"playing", "title", "duration", "elapsed", "rate", "timestamp"}
missing = required - payload.keys()
if missing:
    print(f"!!! в снимке нет обязательных ключей: {sorted(missing)}", file=sys.stderr)
    print(f"    пришло: {sorted(payload.keys())}", file=sys.stderr)
    sys.exit(1)

if not isinstance(payload["playing"], bool):
    print(f"!!! playing должен быть булевым, пришло {type(payload['playing']).__name__}", file=sys.stderr)
    sys.exit(1)

extra = ""
if "commands" in payload:
    extra = f", команд объявлено: {len(payload['commands'])}"
title = payload["title"] or "—"
print(f"  ✓ хелпер ответил снимком (playing={payload['playing']}, трек: {title[:40]}{extra})")
PY

# Закрытый stdin — контракт жизненного цикла. Без этого perl-хост остаётся
# сиротой после недоступного маршрута или завершения приложения.
echo close > "$CLOSE"
wait "$HOLDER_PID" 2>/dev/null
HOLDER_PID=""
for _ in $(seq 1 30); do
    ! kill -0 "$PERL_PID" 2>/dev/null && break
    sleep 0.1
done
if kill -0 "$PERL_PID" 2>/dev/null; then
    fail "хелпер не завершился за 3с после закрытия stdin"
fi
wait "$PERL_PID" 2>/dev/null
PERL_PID=""
echo "  ✓ хелпер завершился после закрытия stdin"
