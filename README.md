# zapret2 на Яндекс Станции

Универсальный обход DPI **прямо на колонке** — без установки zapret на роутер.

Подходит, когда провайдер режет YouTube, Discord или другие сервисы, а поставить
обход на роутер нельзя или не хочется. Скрипт ставит [zapret2](https://github.com/bol-van/zapret2)
(`nfqws2`) на саму Станцию и обрабатывает её исходящий трафик. Остальные
устройства в сети не затрагиваются.

Работает для **любого приложения на колонке**: достаточно добавить нужные домены
в хостлист. По умолчанию настроен YouTube / YouTube Music.

Проверено на:

- Яндекс Станция Мини 2 без часов (`yandexmini_2`), прошивка quasar (Buildroot), aarch64
- zapret2 `v1.0.6`, бинарник `linux-arm64` (`nfqws2`)

Технически подойдёт любая Станция с root, `iptables` и поддержкой `NFQUEUE` в
ядре. Установщик сам определяет архитектуру (`aarch64`, `armv7`, `x86_64`).

---

## 1. Как понять, что дело в DPI

Проверить с колонки:

```sh
curl -v --connect-timeout 6 --max-time 12 -o /dev/null https://music.youtube.com/
```

Если видно:

```
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* Connection timed out after 6002 milliseconds
```

значит TCP-соединение установилось, но ответ после TLS ClientHello не приходит.
Это DPI/блокировка TLS, а не DNS и не отсутствие интернета.

Проверить DNS и сеть:

```sh
nslookup music.youtube.com
ping -c1 8.8.8.8
```

> Если TCP-соединение вообще не устанавливается (curl падает на `Trying ...` /
> `Connected`), это блокировка по IP — zapret может не помочь, нужен прокси/VPN.

---

## 2. Требования

- root-доступ на колонке (SSH или ADB);
- ядро с `NFQUEUE` (проверить: `grep -w NFQUEUE /proc/net/ip_tables_targets`);
- `iptables` (есть в прошивке);
- ~2 МБ свободного места в `/data`;
- `curl` или `wget` для скачивания zapret2 (на hackalice обычно есть curl из Entware).

`ipset` **не нужен** — решение специально собрано без него (в прошивке его нет).

Проверка возможностей:

```sh
cat /proc/net/ip_tables_targets | tr '\n' ' '; echo
cat /proc/net/ip_tables_matches | tr '\n' ' '; echo
```

Должны быть `NFQUEUE`, `mark`, `connbytes`.

---

## 3. Быстрая установка

Скопировать эту папку на колонку (или выполнять по SSH) и запустить от root:

```sh
sh install.sh
```

Скрипт:

1. скачивает zapret2 v1.0.6 (`openwrt-embedded`) с GitHub;
2. распаковывает только нужную архитектуру (`ip2net`, `mdig`, `nfqws2`),
   Lua-скрипты и fake-блобы в `/data/opt/zapret2`;
3. создаёт `start.sh`, `stop.sh`, `hosts.txt`;
4. ставит автозапуск `/etc/init.d/S99zapret2`;
5. запускает и проверяет `https://music.youtube.com/`.

Если GitHub с колонки недоступен, скачайте архив на ПК и передайте путь:

```sh
ZAPRET_TAR=/data/tmp/zapret2-v1.0.6-openwrt-embedded.tar.gz sh install.sh
```

Параметры (переменные окружения): `BASE` (куда ставить, по умолчанию
`/data/opt/zapret2`), `ZAPRET_VER` (тег релиза, по умолчанию `v1.0.6`),
`QNUM` (номер NFQUEUE, по умолчанию `200`), `ZAPRET_TAR` (локальный архив).

---

## 4. Ручная установка

### 4.1. Скачать и распаковать zapret2

```sh
VER=v1.0.6
URL="https://github.com/bol-van/zapret2/releases/download/$VER/zapret2-$VER-openwrt-embedded.tar.gz"
BASE=/data/opt/zapret2
TMP=/data/tmp/zapret2-src

mkdir -p "$BASE/bin" "$BASE/lua" "$BASE/files" "$TMP"
curl -fL -o /data/tmp/zapret2.tar.gz "$URL"
gunzip -c /data/tmp/zapret2.tar.gz | tar -x -C "$TMP"

SRC="$TMP/zapret2-$VER"
cp "$SRC"/binaries/linux-arm64/{ip2net,mdig,nfqws2} "$BASE/bin/"
for f in "$SRC"/lua/*.lua.gz; do
    gunzip -c "$f" > "$BASE/lua/$(basename "$f" .gz)"
done
cp -r "$SRC"/files/fake "$BASE/files/"
chmod +x "$BASE"/bin/*
```

> На hackalice `curl` берётся из Entware: `/opt/bin/curl`, может понадобиться
> `export LD_LIBRARY_PATH=/opt/lib`. Архитектуру (`linux-arm64` / `linux-arm` /
> `linux-x86_64`) выберите по `uname -m`.

### 4.2. Хостлист

`/data/opt/zapret2/hosts.txt` — домены, для которых включается обход:

```
youtube.com
youtu.be
youtubei.googleapis.com
youtube.googleapis.com
googlevideo.com
ytimg.com
ggpht.com
googleusercontent.com
```

Поддомены матчатся автоматически: `googlevideo.com` покрывает все
`rr*.googlevideo.com`. Просто добавьте свои домены (например, `discord.com`,
`discord.gg`, `cdn.discordapp.com`) и перезапустите сервис.

### 4.3. Запуск nfqws2 + правила iptables

`start.sh` (лежит в `files/start.sh`, ставится в `/data/opt/zapret2/start.sh`):

- запускает `nfqws2` со стратегией из дефолтного конфига zapret2:
  - HTTP (80): `fake` + `multisplit`
  - TLS (443): `fake` + `multidisorder`
- добавляет цепочку `ZAPRET2` в `mangle/POSTROUTING`:
  - только исходящий трафик через WAN-интерфейс (определяется автоматически);
  - только первые 20 пакетов соединения (`connbytes`);
  - пакеты с меткой `0x40000000` (сгенерированные самим nfqws2) не заворачиваются —
    защита от петли;
  - `--queue-bypass`: если nfqws2 упадёт, трафик не встанет.

Правила **исходящие**, поэтому SSH (2222), ADB (5555) и остальной трафик не
страдают.

### 4.4. Автозапуск

`/etc/init.d/S99zapret2` (rootfs только для чтения, поэтому нужен remount):

```sh
mount -o remount,rw /
cp files/S99zapret2 /etc/init.d/S99zapret2
chmod 755 /etc/init.d/S99zapret2
sync
mount -o remount,ro /
```

`S99` — чтобы стартовать после `S40wifi`/`S41dhcpcd`.

---

## 5. Проверка

```sh
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 https://music.youtube.com/
# 200
```

Счётчики правил:

```sh
iptables -t mangle -L ZAPRET2 -n -v
```

`nfqws2` должен быть в процессах, лог — `/data/opt/zapret2/nfqws2.log`.

Проверить конкретный сервис можно обычным `curl` к его домену — ответ должен
прийти быстро, без зависания на TLS.

---

## 6. Управление

```sh
/data/opt/zapret2/start.sh     # запустить / перезапустить
/data/opt/zapret2/stop.sh      # остановить и снять правила
tail -f /data/opt/zapret2/nfqws2.log
iptables -t mangle -L ZAPRET2 -n -v
```

После перезагрузки всё поднимается само (`S99zapret2`).

---

## 7. Если не заработало

1. **Проверить, что curl всё ещё виснет на ClientHello.** Если TCP не
   устанавливается — это блок по IP, zapret не поможет.
2. **Проверить, что nfqws2 живой** и правила имеют ненулевые счётчики:
   `iptables -t mangle -L ZAPRET2 -n -v`.
3. **Проверить, что домен в хостлисте.** Для теста можно временно убрать
   `--hostlist` — тогда десинк применяется ко всем TLS-соединениям.
4. **Подобрать другую стратегию.** В релизе zapret2 есть `blockcheck2.sh` —
   он перебирает стратегии и показывает рабочую. Запускать прямо на колонке.
5. **Логи nfqws2** — `/data/opt/zapret2/nfqws2.log`; при необходимости добавить
   `--debug=1` в `start.sh`.
6. **Место в `/data`.** У колонки мало места, следить за `df -h /data`.

### QUIC / UDP 443

По умолчанию обрабатывается только TCP 80/443. Некоторым приложениям этого
хватает, но если сервис настойчиво использует QUIC, можно добавить UDP-профиль в
`start.sh`:

```sh
--filter-udp=443 --filter-l7=quic --hostlist=$HOSTLIST --payload=quic_initial \
    --lua-desync=fake:blob=fake_default_quic:repeats=6
```

и правило:

```sh
iptables -t mangle -A ZAPRET2 -o "$IFACE" -p udp --dport 443 \
    -m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:5 \
    -j NFQUEUE --queue-num $QNUM --queue-bypass
```

Альтернатива — заблокировать QUIC на колонке, чтобы приложение откатилось на
TCP (`iptables -A OUTPUT -p udp --dport 443 -j REJECT`), но это грубее.

---

## 8. Файлы в этой папке

```
README.md          — этот документ
install.sh         — автоматическая установка на колонку
files/start.sh     — запуск nfqws2 + iptables
files/stop.sh      — остановка
files/hosts.txt    — хостлист (по умолчанию YouTube)
files/S99zapret2   — init-скрипт автозапуска
```

---

## 9. Дисклеймер

- Всё делается на ваш собственный девайс под root; используйте на свой страх и риск.
- zapret2 распространяется под своей лицензией — см. репозиторий
  [bol-van/zapret2](https://github.com/bol-van/zapret2).
- Обход применяется только к трафику самой колонки. Для остальных устройств
  нужен zapret на роутере/шлюзе или прокси.
- При обновлении прошивки/сбросе `/data` установку нужно повторить.
