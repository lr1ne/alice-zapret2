#!/bin/sh
# Start zapret2 nfqws2 on the station itself.
# Domains to process are listed in $BASE/hosts.txt (YouTube by default).
# Requires: root, iptables with NFQUEUE, files in $BASE.
BASE=${BASE:-/data/opt/zapret2}
MARK=0x40000000
QNUM=${QNUM:-200}
HOSTLIST=$BASE/hosts.txt
IFACE=${IFACE:-$(ip route 2>/dev/null | awk '/^default/{print $5; exit}')}
[ -n "$IFACE" ] || IFACE=wlan0

"$BASE/stop.sh" >/dev/null 2>&1

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
sleep 1

# connbytes limits the number of packets sent to userspace.
# If the kernel lacks connbytes, fall back to queueing all packets.
CONNB=""
grep -qw connbytes /proc/net/ip_tables_matches 2>/dev/null &&
    CONNB="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:20"

iptables -t mangle -N ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2
iptables -t mangle -A ZAPRET2 -m mark --mark $MARK/$MARK -j RETURN
iptables -t mangle -A ZAPRET2 -o "$IFACE" -p tcp --dport 80 $CONNB -j NFQUEUE --queue-num $QNUM --queue-bypass
iptables -t mangle -A ZAPRET2 -o "$IFACE" -p tcp --dport 443 $CONNB -j NFQUEUE --queue-num $QNUM --queue-bypass
iptables -t mangle -C POSTROUTING -j ZAPRET2 2>/dev/null ||
    iptables -t mangle -I POSTROUTING -j ZAPRET2
exit 0
