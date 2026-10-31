#!/bin/sh
# stop.sh — остановка nfqws2 и удаление правил iptables.
#
# Порядок действий:
#   1) завершаем процесс по PID из nfqws2.pid;
#   2) на случай устаревшего pid-файла добиваем все nfqws2 через killall;
#   3) удаляем правило из POSTROUTING, очищаем и удаляем цепочку ZAPRET2.
#
# Параметры:
#   BASE=/data/opt/zapret2   каталог установки
#
# Скрипт можно вызывать повторно: если процесса или правил уже нет,
# ошибки подавляются, и скрипт всё равно завершается успешно.

BASE=${BASE:-/data/opt/zapret2}

# Основной способ остановки — по сохранённому PID.
if [ -f "$BASE/nfqws2.pid" ]; then
    kill "$(cat "$BASE/nfqws2.pid")" 2>/dev/null
    rm -f "$BASE/nfqws2.pid"
fi
# Страховка: pid-файл мог остаться от прошлой загрузки или быть потерян.
killall nfqws2 2>/dev/null

# Снимаем правило-переходник из POSTROUTING, затем очищаем (-F) и удаляем (-X)
# саму цепочку ZAPRET2. Ошибки игнорируем: при повторном запуске правил
# может уже не быть.
iptables -t mangle -D POSTROUTING -j ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2 2>/dev/null
iptables -t mangle -X ZAPRET2 2>/dev/null
exit 0
