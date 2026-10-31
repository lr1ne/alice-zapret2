#!/bin/sh
# start.sh — запуск nfqws2 и установка правил iptables.
#
# Что делает скрипт:
#   1) останавливает предыдущий экземпляр (stop.sh), чтобы не запускать
#      два демона и не дублировать правила;
#   2) запускает nfqws2 с Lua-стратегиями обхода DPI из zapret2;
#   3) создаёт цепочку ZAPRET2 в mangle/POSTROUTING и направляет в NFQUEUE
#      исходящий HTTP/HTTPS-трафик станции.
#
# Параметры можно переопределить переменными окружения:
#   BASE=/data/opt/zapret2   каталог установки
#   QNUM=200                 номер очереди NFQUEUE
#   IFACE=wlan0              сетевой интерфейс (по умолчанию — из default-маршрута)
#
# Скрипт безопасно запускать повторно: старые правила и процесс заменяются.

BASE=${BASE:-/data/opt/zapret2}
MARK=0x40000000                 # метка, которой nfqws2 помечает свои пакеты (защита от петли)
QNUM=${QNUM:-200}               # очередь NFQUEUE, должна совпадать с --qnum у nfqws2
HOSTLIST=$BASE/hosts.txt        # домены, для которых включается обход
# WAN-интерфейс берём из маршрута по умолчанию. Если определить не удалось,
# используем wlan0 — типичный интерфейс Станции.
IFACE=${IFACE:-$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')}
[ -n "$IFACE" ] || IFACE=wlan0

# Сначала останавливаем уже запущенный экземпляр и снимаем его правила,
# иначе новая цепочка ZAPRET2 будет добавлена поверх старой.
"$BASE/stop.sh" >/dev/null 2>&1

# Запуск nfqws2 в фоне.
#   --qnum       — номер очереди, из которой демон читает пакеты;
#   --fwmark     — метка для пакетов, которые генерирует сам nfqws2,
#                  чтобы iptables не заворачивал их обратно в очередь;
#   --lua-init   — подключаем библиотеку zapret2 и готовые стратегии;
#   --filter-*   — какие пакеты обрабатывать (TCP 80/443, только из хостлиста);
#   --payload    — на каком этапе протокола вмешиваться;
#   --lua-desync — сами действия обхода DPI.
#
# HTTP (80): fake-пакет из блоба fake_default_http с опцией TCP MD5
# (чтобы он выглядел валидным), затем multisplit — разделение запроса
# на части сразу после HTTP-метода.
# TLS (443): fake-пакет из блоба fake_default_tls со сдвигом TCP sequence
# (-10000) и multidisorder — отправка фрагментов ClientHello в обратном порядке.
#
# Вывод демона пишется в лог, PID — в файл, чтобы stop.sh мог его найти.
"$BASE/bin/nfqws2" --qnum=$QNUM --fwmark=$MARK \
    --lua-init=@$BASE/lua/zapret-lib.lua \
    --lua-init=@$BASE/lua/zapret-antidpi.lua \
    --lua-init=@$BASE/lua/zapret-auto.lua \
    --filter-tcp=80 --filter-l7=http --hostlist=$HOSTLIST --payload=http_req \
    --lua-desync=fake:blob=fake_default_http:tcp_md5 \
    --lua-desync=multisplit:pos=method+2 --new \
    --filter-tcp=443 --filter-l7=tls --hostlist=$HOSTLIST --payload=tls_client_hello \
    --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
    --lua-desync=multidisorder:pos=1,midsld \
  >>"$BASE/nfqws2.log" 2>&1 &
echo $! > "$BASE/nfqws2.pid"
# Небольшая пауза, чтобы nfqws2 успел открыть очередь до добавления правил.
sleep 1

# connbytes ограничивает количество пакетов, отправляемых в пользовательское
# пространство: обрабатываем только первые 20 пакетов каждого соединения.
# Остальные идут напрямую и не нагружают слабый CPU колонки.
# Если в ядре нет match connbytes, CONNB остаётся пустым и в очередь попадают
# все пакеты (медленнее, но работает).
CONNB=""
grep -qw connbytes /proc/net/ip_tables_matches 2>/dev/null && CONNB="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:20"

# Создаём цепочку ZAPRET2. -N может завершиться ошибкой, если цепочка уже
# существует, поэтому ошибку игнорируем, а затем очищаем цепочку (-F),
# чтобы начать с чистого состояния.
iptables -t mangle -N ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2
# Пакеты с меткой nfqws2 не обрабатываем повторно — защита от бесконечной петли.
iptables -t mangle -A ZAPRET2 -m mark --mark $MARK/$MARK -j RETURN
# Заворачиваем только исходящий трафик через WAN-интерфейс на порты 80 и 443.
# --queue-bypass: если nfqws2 упадёт, трафик пойдёт дальше, а не встанет.
iptables -t mangle -A ZAPRET2 -o "$IFACE" -p tcp --dport 80 $CONNB -j NFQUEUE --queue-num $QNUM --queue-bypass
iptables -t mangle -A ZAPRET2 -o "$IFACE" -p tcp --dport 443 $CONNB -j NFQUEUE --queue-num $QNUM --queue-bypass
# Подключаем цепочку к POSTROUTING ровно один раз: -C проверяет наличие
# правила, -I добавляет его в начало, если проверка не прошла.
iptables -t mangle -C POSTROUTING -j ZAPRET2 2>/dev/null || iptables -t mangle -I POSTROUTING -j ZAPRET2
exit 0
