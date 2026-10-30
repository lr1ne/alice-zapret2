#!/bin/sh
# install.sh — install zapret2 (nfqws2) on a Yandex Station
# to bypass DPI for the station's own traffic, without a router.
#
# Run ON THE STATION as root (SSH :2222 or ADB):
#   sh install.sh
#
# Offline install (archive pre-downloaded):
#   ZAPRET_TAR=/data/tmp/zapret2-v1.0.6-openwrt-embedded.tar.gz sh install.sh
#
# Options (env):
#   BASE=/data/opt/zapret2   install dir
#   ZAPRET_VER=v1.0.6        release tag (keep the leading "v")
#   ZAPRET_TAR=/path.tar.gz  use local archive instead of downloading
#   QNUM=200                 NFQUEUE number
#
# Domains to process are listed in $BASE/hosts.txt (YouTube by default).

set -eu

BASE=${BASE:-/data/opt/zapret2}
VER=${ZAPRET_VER:-v1.0.6}
QNUM=${QNUM:-200}
URL="https://github.com/bol-van/zapret2/releases/download/$VER/zapret2-$VER-openwrt-embedded.tar.gz"
ZAPRET_TAR=${ZAPRET_TAR:-}

say(){ echo "[zapret2] $*"; }
die(){ echo "[zapret2] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"

case "$(uname -m)" in
    aarch64|arm64)   ARCH=linux-arm64 ;;
    armv7l|armv6l|arm) ARCH=linux-arm ;;
    x86_64|amd64)    ARCH=linux-x86_64 ;;
    *) die "unsupported CPU arch: $(uname -m)" ;;
esac

command -v iptables >/dev/null 2>&1 || die "iptables not found"
grep -qw NFQUEUE /proc/net/ip_tables_targets 2>/dev/null || die "kernel does not support NFQUEUE"

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

if [ -n "$CURL" ]; then
    DL="$CURL -fL --retry 2 --connect-timeout 15 -o"
elif [ -n "$WGET" ]; then
    DL="$WGET -O"
else
    die "need curl or wget (on Entware: yse install curl)"
fi

mkdir -p /data/tmp
TMPD=$(mktemp -d /data/tmp/zapret2.XXXXXX 2>/dev/null || mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

if [ -n "$ZAPRET_TAR" ]; then
    [ -f "$ZAPRET_TAR" ] || die "archive not found: $ZAPRET_TAR"
    say "using local archive: $ZAPRET_TAR"
    cp "$ZAPRET_TAR" "$TMPD/zapret2.tar.gz"
else
    say "downloading $URL"
    $DL "$TMPD/zapret2.tar.gz" "$URL" || die "download failed (pass ZAPRET_TAR=... for offline install)"
fi
[ -s "$TMPD/zapret2.tar.gz" ] || die "archive is empty"

say "extracting only $ARCH binaries, lua and fake blobs"
gunzip -c "$TMPD/zapret2.tar.gz" | tar -x -C "$TMPD" \
    "zapret2-$VER/binaries/$ARCH" \
    "zapret2-$VER/lua" \
    "zapret2-$VER/files/fake" || die "extract failed"

SRC="$TMPD/zapret2-$VER"
[ -d "$SRC/binaries/$ARCH" ] || die "binaries for $ARCH not found in archive"

# stop the running instance: writing to a running executable gives ETXTBSY
[ -x "$BASE/stop.sh" ] && "$BASE/stop.sh" >/dev/null 2>&1 || true

mkdir -p "$BASE/bin" "$BASE/lua" "$BASE/files"
cp "$SRC/binaries/$ARCH/ip2net" "$SRC/binaries/$ARCH/mdig" "$SRC/binaries/$ARCH/nfqws2" "$BASE/bin/"
if ls "$SRC"/lua/*.lua.gz >/dev/null 2>&1; then
    for f in "$SRC"/lua/*.lua.gz; do
        gunzip -c "$f" > "$BASE/lua/$(basename "$f" .gz)"
    done
else
    cp "$SRC"/lua/*.lua "$BASE/lua/"
fi
[ -d "$BASE/files/fake" ] || cp -r "$SRC/files/fake" "$BASE/files/"
chmod 755 "$BASE/bin/"*

# ---- config files -----------------------------------------------------------
cat > "$BASE/hosts.txt" <<'EOF'
youtube.com
youtu.be
youtubei.googleapis.com
youtube.googleapis.com
googlevideo.com
ytimg.com
ggpht.com
googleusercontent.com
EOF

cat > "$BASE/start.sh" <<EOF
#!/bin/sh
BASE=\${BASE:-$BASE}
MARK=0x40000000
QNUM=\${QNUM:-$QNUM}
HOSTLIST=\$BASE/hosts.txt
IFACE=\${IFACE:-\$(ip route 2>/dev/null | awk '/^default/{print \$5; exit}')}
[ -n "\$IFACE" ] || IFACE=wlan0

"\$BASE/stop.sh" >/dev/null 2>&1

"\$BASE/bin/nfqws2" --qnum=\$QNUM --fwmark=\$MARK \\
  --lua-init=@\$BASE/lua/zapret-lib.lua \\
  --lua-init=@\$BASE/lua/zapret-antidpi.lua \\
  --lua-init=@\$BASE/lua/zapret-auto.lua \\
  --filter-tcp=80 --filter-l7=http --hostlist=\$HOSTLIST --payload=http_req \\
      --lua-desync=fake:blob=fake_default_http:tcp_md5 \\
      --lua-desync=multisplit:pos=method+2 --new \\
  --filter-tcp=443 --filter-l7=tls --hostlist=\$HOSTLIST --payload=tls_client_hello \\
      --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \\
      --lua-desync=multidisorder:pos=1,midsld \\
  >>"\$BASE/nfqws2.log" 2>&1 &
echo \$! > "\$BASE/nfqws2.pid"
sleep 1

CONNB=""
grep -qw connbytes /proc/net/ip_tables_matches 2>/dev/null &&
    CONNB="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:20"

iptables -t mangle -N ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2
iptables -t mangle -A ZAPRET2 -m mark --mark \$MARK/\$MARK -j RETURN
iptables -t mangle -A ZAPRET2 -o "\$IFACE" -p tcp --dport 80 \$CONNB -j NFQUEUE --queue-num \$QNUM --queue-bypass
iptables -t mangle -A ZAPRET2 -o "\$IFACE" -p tcp --dport 443 \$CONNB -j NFQUEUE --queue-num \$QNUM --queue-bypass
iptables -t mangle -C POSTROUTING -j ZAPRET2 2>/dev/null ||
    iptables -t mangle -I POSTROUTING -j ZAPRET2
exit 0
EOF

cat > "$BASE/stop.sh" <<EOF
#!/bin/sh
BASE=\${BASE:-$BASE}
if [ -f "\$BASE/nfqws2.pid" ]; then
    kill "\$(cat "\$BASE/nfqws2.pid")" 2>/dev/null
    rm -f "\$BASE/nfqws2.pid"
fi
killall nfqws2 2>/dev/null
iptables -t mangle -D POSTROUTING -j ZAPRET2 2>/dev/null
iptables -t mangle -F ZAPRET2 2>/dev/null
iptables -t mangle -X ZAPRET2 2>/dev/null
exit 0
EOF

cat > "$BASE/S99zapret2" <<'EOF'
#!/bin/sh
case "$1" in
  start)   /data/opt/zapret2/start.sh ;;
  stop)    /data/opt/zapret2/stop.sh ;;
  restart) /data/opt/zapret2/stop.sh; /data/opt/zapret2/start.sh ;;
esac
EOF

chmod 755 "$BASE/start.sh" "$BASE/stop.sh" "$BASE/S99zapret2"
chown -R root:root "$BASE" 2>/dev/null || true

# ---- autostart --------------------------------------------------------------
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

# ---- start + verify ---------------------------------------------------------
"$BASE/start.sh"
sleep 2

say "nfqws2: $(cat "$BASE/nfqws2.pid" 2>/dev/null || echo 'not running')"
iptables -t mangle -L ZAPRET2 -n -v 2>/dev/null || true

if [ -n "$CURL" ]; then
    CODE=$($CURL -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 https://music.youtube.com/ 2>/dev/null || true)
    say "https://music.youtube.com/ -> ${CODE:-fail}"
fi
say "done. manage: $BASE/start.sh | $BASE/stop.sh"
