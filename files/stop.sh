#!/bin/sh
# Stop zapret2 nfqws2 and remove its iptables rules.
BASE=${BASE:-/data/opt/zapret2}

if [ -f "$BASE/nfqws2.pid" ]; then
    kill "$(cat "$BASE/nfqws2.pid")" 2>/dev/null
    rm -f "$BASE/nfqws2.pid"
fi
killall nfqws2 2>/dev/null

iptables -t mangle -D POSTROUTING -j ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2 2>/dev/null
iptables -t mangle -X ZAPRET2 2>/dev/null
exit 0
