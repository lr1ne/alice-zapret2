#!/bin/sh
# uninstall.sh — полное удаление zapret2 с Яндекс Станции.
#
# Порядок действий:
#   1) останавливает nfqws2 и снимает правила iptables (через stop.sh);
#   2) удаляет автозапуск /etc/init.d/S99zapret2;
#   3) удаляет каталог установки со всеми файлами, логами и pid-файлом.
#
# Запуск НА СТАНЦИИ от имени root (через SSH :2222 или ADB):
#   sh /data/opt/zapret2/uninstall.sh
#
# Параметры (переменные окружения):
#   BASE=/data/opt/zapret2   каталог установки (должен совпадать с install.sh)
#
# Скрипт можно вызывать повторно: отсутствие процесса, правил или файлов
# не считается ошибкой.

set -u

BASE=${BASE:-/data/opt/zapret2}

say(){ echo "[zapret2] $*"; }
die(){ echo "[zapret2] ERROR: $*" >&2; exit 1; }

# Удаление затрагивает iptables, /etc/init.d и /data — нужен root.
[ "$(id -u)" = 0 ] || die "run as root"

# Защита от опечатки в BASE: не даём удалить корень или пустой путь.
case "$BASE" in
    ""|"/"|"/data"|"/data/")
        die "refusing to remove unsafe BASE='$BASE'"
        ;;
esac

# ---- Остановка сервиса и снятие правил --------------------------------------
# Если stop.sh на месте, он корректно завершит процесс и удалит цепочку
# ZAPRET2. Если его уже нет (например, каталог повреждён), делаем то же самое
# вручную, чтобы не оставить правила iptables висеть.
if [ -x "$BASE/stop.sh" ]; then
    BASE="$BASE" "$BASE/stop.sh" >/dev/null 2>&1 || true
    say "service stopped"
else
    say "stop.sh not found, cleaning up manually"
fi

# Страховка на случай потерянного pid-файла (killall есть не везде).
if command -v killall >/dev/null 2>&1; then
    killall nfqws2 2>/dev/null || true
elif command -v pkill >/dev/null 2>&1; then
    pkill -x nfqws2 2>/dev/null || true
fi
iptables -t mangle -D POSTROUTING -j ZAPRET2 2>/dev/null || true
iptables -t mangle -F ZAPRET2 2>/dev/null || true
iptables -t mangle -X ZAPRET2 2>/dev/null || true

# ---- Удаление автозапуска ---------------------------------------------------
# /etc/init.d находится на rootfs, смонтированном только для чтения,
# поэтому раздел нужно ненадолго перемонтировать в rw.
if [ -f /etc/init.d/S99zapret2 ]; then
    if mount -o remount,rw / 2>/dev/null; then
        rm -f /etc/init.d/S99zapret2
        sync
        mount -o remount,ro / 2>/dev/null || true
        say "autostart removed: /etc/init.d/S99zapret2"
    else
        say "WARNING: rootfs is read-only and remount failed; remove /etc/init.d/S99zapret2 manually"
    fi
else
    say "autostart not found, nothing to remove"
fi

# ---- Удаление каталога установки --------------------------------------------
# Здесь лежат бинарники, Lua-скрипты, конфиги, логи и сам этот скрипт.
# На Linux запущенный файл можно удалить — процесс продолжит работу до выхода.
if [ -d "$BASE" ]; then
    rm -rf "$BASE"
    say "removed $BASE"
else
    say "$BASE not found, nothing to remove"
fi

say "done. zapret2 uninstalled"
