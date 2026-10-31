#!/bin/sh
# install.sh — установка zapret2 (nfqws2) на Яндекс Станцию.
#
# Назначение:
#   Обход DPI-блокировок для трафика самой колонки, без роутера.
#   Обрабатывается только исходящий трафик станции, остальные устройства
#   в сети не затрагиваются.
#
# Запуск НА СТАНЦИИ от имени root (через SSH :2222 или ADB):
#   sh install.sh
#
# Установка без интернета (архив уже скачан и передан на станцию):
#   ZAPRET_TAR=/data/tmp/zapret2-v1.0.6-openwrt-embedded.tar.gz sh install.sh
#
# Параметры (переменные окружения):
#   BASE=/data/opt/zapret2   каталог установки
#   ZAPRET_VER=v1.0.6        тег релиза (буква "v" в начале обязательна)
#   ZAPRET_TAR=/path.tar.gz  локальный архив вместо скачивания
#   QNUM=200                 номер очереди NFQUEUE
#
# Список доменов для обработки лежит в $BASE/hosts.txt (по умолчанию YouTube).
#
# Конфигурационные файлы (start.sh, stop.sh, hosts.txt, S99zapret2) берутся
# из каталога рядом с этим скриптом (или из подкаталога files/) и копируются
# в $BASE. Благодаря этому их можно править обычным редактором, не трогая
# установщик.

# -e — прерывать выполнение при первой ошибке;
# -u — считать обращение к незаданной переменной ошибкой.
set -eu

# ---- Параметры установки ----------------------------------------------------
# Значения по умолчанию можно переопределить переменными окружения.
BASE=${BASE:-/data/opt/zapret2}   # куда ставить zapret2
VER=${ZAPRET_VER:-v1.0.6}         # версия релиза zapret2
QNUM=${QNUM:-200}                 # номер очереди NFQUEUE (общий для nfqws2 и iptables)
URL="https://github.com/bol-van/zapret2/releases/download/$VER/zapret2-$VER-openwrt-embedded.tar.gz"
ZAPRET_TAR=${ZAPRET_TAR:-}        # пусто = скачивать архив из интернета

# Короткие функции для единообразных сообщений в логе.
say(){ echo "[zapret2] $*"; }
die(){ echo "[zapret2] ERROR: $*" >&2; exit 1; }

# ---- Проверка окружения -----------------------------------------------------
# Все действия требуют root: установка в /data, работа с iptables и правка
# /etc/init.d выполняются только от суперпользователя.
[ "$(id -u)" = 0 ] || die "run as root"

# Определяем архитектуру станции и сопоставляем её с каталогом бинарников
# в архиве zapret2. Неизвестная архитектура — сразу ошибка, иначе можно
# поставить неподходящий бинарник.
case "$(uname -m)" in
    aarch64|arm64)   ARCH=linux-arm64 ;;
    armv7l|armv6l|arm) ARCH=linux-arm ;;
    x86_64|amd64)    ARCH=linux-x86_64 ;;
    *) die "unsupported CPU arch: $(uname -m)" ;;
esac

# Без iptables и поддержки NFQUEUE в ядре nfqws2 работать не сможет:
# именно через NFQUEUE пакеты попадают в userspace-обработчик.
command -v iptables >/dev/null 2>&1 || die "iptables not found"
grep -qw NFQUEUE /proc/net/ip_tables_targets 2>/dev/null || die "kernel does not support NFQUEUE"

# ---- Поиск curl/wget --------------------------------------------------------
# На hackalice (Entware) нужные утилиты могут лежать не в PATH, а в /opt/bin
# или /data/opt/bin. Для них дополнительно добавляем каталог библиотек
# в LD_LIBRARY_PATH, иначе бинарник не запустится.
CURL=
if command -v curl >/dev/null 2>&1; then
    CURL="curl"
elif [ -x /opt/bin/curl ]; then
    CURL="/opt/bin/curl"
    export LD_LIBRARY_PATH="/opt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
elif [ -x /data/opt/bin/curl ]; then
    CURL="/data/opt/bin/curl"
    export LD_LIBRARY_PATH="/data/opt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

WGET=
if command -v wget >/dev/null 2>&1; then
    WGET="wget"
elif [ -x /opt/bin/wget ]; then
    WGET="/opt/bin/wget"
    export LD_LIBRARY_PATH="/opt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Собираем команду скачивания. curl предпочтительнее: он умеет завершаться
# с ошибкой на HTTP 4xx/5xx (-f) и повторять попытку (--retry). wget —
# запасной вариант. Если нет ни того, ни другого, установка невозможна.
if [ -n "$CURL" ]; then
    DL="$CURL -fL --retry 2 --connect-timeout 15 -o"
elif [ -n "$WGET" ]; then
    DL="$WGET -O"
else
    die "need curl or wget (on Entware: yse install curl)"
fi

# ---- Временный каталог ------------------------------------------------------
# Архив и распакованные файлы складываем в /data/tmp, где обычно есть место.
# trap гарантирует удаление временного каталога при любом выходе, включая
# аварийный, чтобы не забивать небольшой раздел /data.
mkdir -p /data/tmp
TMPD=$(mktemp -d /data/tmp/zapret2.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ---- Получение архива -------------------------------------------------------
if [ -n "$ZAPRET_TAR" ]; then
    # Локальный архив: копируем во временный каталог, чтобы дальнейшая логика
    # работала с одним и тем же путём независимо от источника.
    [ -f "$ZAPRET_TAR" ] || die "archive not found: $ZAPRET_TAR"
    say "using local archive: $ZAPRET_TAR"
    cp "$ZAPRET_TAR" "$TMPD/zapret2.tar.gz"
else
    # Скачиваем релиз с GitHub. Если сеть недоступна, подсказываем
    # про установку из локального архива через ZAPRET_TAR.
    say "downloading $URL"
    $DL "$TMPD/zapret2.tar.gz" "$URL" || die "download failed (pass ZAPRET_TAR=... for offline install)"
fi
[ -s "$TMPD/zapret2.tar.gz" ] || die "archive is empty"

# ---- Распаковка -------------------------------------------------------------
# Из архива нужны только:
#   binaries/<arch> — исполняемые файлы ip2net, mdig, nfqws2;
#   lua             — Lua-скрипты стратегий zapret2;
#   files/fake      — готовые fake-блобы для подмены пакетов.
# Документация, исходники и бинарники других архитектур не нужны и только
# занимают место на станции.
say "extracting only $ARCH binaries, lua and fake blobs"
gunzip -c "$TMPD/zapret2.tar.gz" | tar -x -C "$TMPD" \
    "zapret2-$VER/binaries/$ARCH" \
    "zapret2-$VER/lua" \
    "zapret2-$VER/files/fake" || die "extract failed"

SRC="$TMPD/zapret2-$VER"
[ -d "$SRC/binaries/$ARCH" ] || die "binaries for $ARCH not found in archive"

# ---- Остановка предыдущей установки -----------------------------------------
# Если zapret2 уже запущен, сначала останавливаем его: запись в работающий
# исполняемый файл даёт ошибку ETXTBSY, и копирование бинарников сорвётся.
[ -x "$BASE/stop.sh" ] && "$BASE/stop.sh" >/dev/null 2>&1 || true

# ---- Установка бинарников и Lua ---------------------------------------------
mkdir -p "$BASE/bin" "$BASE/lua" "$BASE/files"
cp "$SRC/binaries/$ARCH/ip2net" "$SRC/binaries/$ARCH/mdig" "$SRC/binaries/$ARCH/nfqws2" "$BASE/bin/"
# В разных сборках zapret2 Lua лежит либо сжатым (*.lua.gz), либо обычным.
# Поддерживаем оба варианта, чтобы не зависеть от версии релиза.
if ls "$SRC"/lua/*.lua.gz >/dev/null 2>&1; then
    for f in "$SRC"/lua/*.lua.gz; do
        gunzip -c "$f" > "$BASE/lua/$(basename "$f" .gz)"
    done
else
    cp "$SRC"/lua/*.lua "$BASE/lua/"
fi
# fake-блобы не перезаписываем: если пользователь их менял, его правки сохранятся.
[ -d "$BASE/files/fake" ] || cp -r "$SRC/files/fake" "$BASE/files/"
chmod 755 "$BASE/bin/"*

# ---- Конфигурационные файлы -------------------------------------------------
# start.sh, stop.sh, hosts.txt и S99zapret2 не генерируются внутри скрипта,
# а копируются из каталога с install.sh. Так их можно редактировать как
# обычные файлы, не трогая установщик.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRCDIR=$HERE
# Поддерживаем две раскладки: файлы лежат рядом с install.sh или в files/.
[ -f "$HERE/files/start.sh" ] && SRCDIR="$HERE/files"
for f in hosts.txt start.sh stop.sh S99zapret2; do
    [ -f "$SRCDIR/$f" ] || die "missing $SRCDIR/$f"
done

say "copying config files from $SRCDIR"
cp "$SRCDIR/hosts.txt"  "$BASE/hosts.txt"
cp "$SRCDIR/start.sh"   "$BASE/start.sh"
cp "$SRCDIR/stop.sh"    "$BASE/stop.sh"
cp "$SRCDIR/S99zapret2" "$BASE/S99zapret2"

chmod 755 "$BASE/start.sh" "$BASE/stop.sh" "$BASE/S99zapret2"
# Владелец всех установленных файлов — root, чтобы демон и init-скрипт
# могли работать после перезагрузки.
chown -R root:root "$BASE" 2>/dev/null || true

# ---- Автозапуск -------------------------------------------------------------
# В прошивке станции /etc/init.d находится на rootfs, смонтированном только
# для чтения. Поэтому сначала перемонтируем раздел в rw, копируем init-скрипт,
# затем возвращаем ro, чтобы не оставлять систему в изменяемом состоянии.
# S99zapret2 стартует после сетевых сервисов (S40wifi/S41dhcpcd), когда
# интерфейс уже поднят и правила можно применять.
if [ -d /etc/init.d ]; then
    if mount -o remount,rw / 2>/dev/null; then
        cp "$BASE/S99zapret2" /etc/init.d/S99zapret2
        chmod 755 /etc/init.d/S99zapret2
        sync
        mount -o remount,ro / 2>/dev/null || true
        say "autostart installed: /etc/init.d/S99zapret2"
    else
        say "WARNING: rootfs is read-only and remount failed; autostart not installed"
    fi
fi

# ---- Запуск и проверка ------------------------------------------------------
# Передаём BASE и QNUM, заданные при установке: скопированные start.sh/stop.sh
# используют значения по умолчанию, если переменные не заданы.
BASE="$BASE" QNUM="$QNUM" "$BASE/start.sh"
# Даём nfqws2 время запуститься и создать pid-файл.
sleep 2

# Показываем PID демона (или "not running", если он не поднялся) и счётчики
# правил iptables, чтобы сразу было видно, работает ли обход.
say "nfqws2: $(cat "$BASE/nfqws2.pid" 2>/dev/null || echo 'not running')"
iptables -t mangle -L ZAPRET2 -n -v 2>/dev/null || true

# Финальная проверка: запрашиваем music.youtube.com. Код 200 означает, что
# TLS-соединение проходит. Пустой ответ/fail — обход не сработал.
if [ -n "$CURL" ]; then
    CODE=$($CURL -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 https://music.youtube.com/ 2>/dev/null || true)
    say "https://music.youtube.com/ -> ${CODE:-fail}"
fi
say "done. manage: $BASE/start.sh | $BASE/stop.sh"
