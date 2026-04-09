# Context: IKEv2 VPN → WireGuard → Latvia

## Схема решения

```
[iPhone / macOS / Windows]
         │
         │ IKEv2/IPsec UDP :500, :4500
         ▼
[RU-VPN сервер: 212.67.x.x]
  └── Libreswan (hwdsl2/ipsec-vpn-server в Docker)
         │
         │ WireGuard туннель UDP :51820
         │ 10.0.0.3 ─────────── 10.0.0.1
         ▼
[LAT сервер: 46.x.x.x]
  └── WireGuard exit node + NAT
         │
         ▼
    Интернет (виден латвийский IP)
```

---

## Почему IKEv2 а не OpenVPN / WireGuard напрямую

| | IKEv2 | WireGuard (прямой) |
|---|---|---|
| Встроен в iOS/macOS | ✅ да | ❌ нет (нужно приложение) |
| Встроен в Windows | ✅ да | ❌ нет |
| Настройка профиля | .mobileconfig (один файл) | вручную |
| Reconnect при смене сети | автоматически | вручную |

IKEv2 нативно поддерживается во всех основных ОС без установки приложений.

---

## Почему Docker (hwdsl2/ipsec-vpn-server)

- Libreswan сложен в ручной настройке (сертификаты, ipsec.conf, ключи)
- hwdsl2/ipsec-vpn-server автоматизирует весь процесс
- IKEv2 скрипт генерирует клиентские профили (.mobileconfig, .p12, .sswan)
- Сертификаты сохраняются в volume — переживают пересоздание контейнера

---

## Критическая проблема: Docker bridge vs host network

### Почему bridge НЕЛЬЗЯ использовать

С bridge сетью (`-p 500:500/udp -p 4500:4500/udp`):

1. `docker-proxy` запускается и слушает на 0.0.0.0:500 в **userspace**
2. Когда клиент подключается, пакеты обрабатываются docker-proxy, а не ядром
3. Ответы IKEv2 от контейнера (src: 172.17.0.2) выходят через **WireGuard** (т.к. default route = wg0)
4. Клиент получает ответ от латвийского IP вместо российского → отклоняет

Попытки исправить через `iptables mangle PREROUTING` и `fwmark` не работают, потому что docker-proxy перехватывает пакеты до попадания в iptables.

### Почему host network решает проблему

С `--network=host`:
1. Libreswan слушает напрямую на `eth0: 212.67.x.x:500`
2. IKEv2 ответы уходят с адреса `212.67.x.x`
3. Правило `ip rule add from 212.67.x.x table main` → пакеты идут через eth0
4. Клиент получает ответ от ожидаемого IP ✅

---

## Критическая проблема: left=%defaultroute

### Что происходит

В `/etc/ipsec.d/ikev2.conf` контейнер записывает:
```
left=%defaultroute
```

Libreswan при старте определяет "default route" и привязывает соединение к этому интерфейсу.

С активным WireGuard default route = `wg0` (в Латвию).  
Libreswan привязывает `ikev2-cp` к `wg0` (local: 10.0.0.3).

Клиент подключается к `212.67.x.x:500` (eth0), но соединение `ikev2-cp` ориентировано на `wg0`. Libreswan возвращает `NO_PROPOSAL_CHOSEN` — generic отказ, соединение рвётся через ~0.5 сек.

### Исправление

```bash
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=212.67.x.x/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
```

Изменение **персистентно** — файл находится в смонтированном volume (`~/ikev2-vpn-data`).

После исправления:
```
"ikev2-cp":   host: oriented; local: 212.67.x.x; interface: eth0  ✅
```

---

## Критическая проблема: iptables FORWARD сброс

### Что происходит

При каждом старте контейнер `hwdsl2/ipsec-vpn-server` полностью **перезаписывает** iptables FORWARD chain и добавляет `DROP all` в конец.

WireGuard при старте добавляет:
```
-A FORWARD -i wg0 -j ACCEPT
-A FORWARD -o wg0 -j ACCEPT
```

Но когда контейнер стартует после WireGuard — эти правила стираются.

VPN клиент (192.168.43.x) подключается → трафик идёт на wg0 → FORWARD DROP → страницы не загружаются.

### Исправление

```bash
# Вставить ПЕРЕД DROP правилом контейнера
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT

# NAT для VPN клиентов через wg0 (не eth0!)
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE

# MSS clamp для nested VPN
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Для персистентности используется отдельный systemd сервис `vpn-iptables-fix.service`.

---

## MSS Clamp: почему без него не работает интернет

При подключённом VPN цепочка MTU:
```
eth0 MTU = 1500 байт
  └── WireGuard overhead ~60 байт → wg0 MTU = 1420 байт
        └── IKEv2/IPsec overhead ~60 байт → эффективный MTU ≈ 1360 байт
```

Без MSS clamp большие TCP SYN пакеты (с MSS=1460) отправляются, теряются где-то в туннеле, и соединение зависает. Страницы не загружаются, хотя пинг работает.

```bash
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

---

## VPN_PUBLIC_IP в vpn.env: почему важен

При старте контейнера с `--network=host` и активным WireGuard:
- Контейнер определяет внешний IP через `curl ifconfig.me` или похожим способом
- Получает латвийский IP (46.x.x.x) потому что весь трафик идёт через LAT
- Генерирует IKEv2 сертификат для латвийского IP
- Клиенты настроены на российский IP → сертификат не совпадает

Решение: явно задать в `vpn.env`:
```
VPN_PUBLIC_IP=212.67.x.x  ← реальный IP RU-VPN сервера
```

### Важное ограничение VPN_PUBLIC_IP

Согласно [документации hwdsl2](https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip):

> **"Note that this variable has no effect for IKEv2 mode, if IKEv2 is already set up in the Docker container."**

Если `~/ikev2-vpn-data/ikev2.conf` уже существует (повторный запуск, старый volume), `VPN_PUBLIC_IP` не обновит IKEv2 сертификат. Два варианта:

**Вариант 1 — удалить только ikev2.conf (клиентские сертификаты сохранятся):**
```bash
rm ~/ikev2-vpn-data/ikev2.conf
# пересоздать контейнер → IKEv2 сгенерируется заново с правильным IP
```

**Вариант 2 — полный сброс IKEv2 (все клиенты будут удалены):**
```bash
docker exec ipsec-vpn-server ikev2.sh
# → 6) Remove IKEv2
# Затем пересоздать контейнер
```

В обоих случаях `left=` всё равно нужно исправить через `sed` после перезапуска.

---

## VPN_IKEV2_ONLY=yes

Добавляй в `vpn.env` чтобы отключить L2TP и XAuth (Cisco IPsec) режимы:
```
VPN_IKEV2_ONLY=yes
```

Мы используем только IKEv2. Отключение других режимов:
- Уменьшает поверхность атаки
- Убирает xl2tpd процесс из контейнера
- Упрощает iptables правила контейнера

---

## Адресация WireGuard

```
LAT сервер:    10.0.0.1/24  (ListenPort 51820)
RU-SOCKS:      10.0.0.2/32  (если используется совместно)
RU-VPN:        10.0.0.3/32
```

---

## Файлы и их назначение

### RU-VPN сервер
| Файл | Назначение |
|------|-----------|
| `/etc/wireguard/wg0.conf` | WireGuard туннель к LAT |
| `/etc/wireguard/private.key` | WG приватный ключ (не передавать!) |
| `/etc/wireguard/public.key` | WG публичный ключ (для LAT peer) |
| `~/vpn.env` | Переменные для Docker контейнера |
| `~/ikev2-vpn-data/` | Volume: сертификаты, ключи, конфиги IKEv2 |
| `~/ikev2-vpn-data/ikev2.conf` | Конфиг соединения (правим left=) |
| `/usr/local/bin/vpn-iptables-fix.sh` | Скрипт восстановления iptables |
| `/etc/systemd/system/vpn-iptables-fix.service` | Systemd сервис для персистентности |

### LAT сервер
| Файл | Назначение |
|------|-----------|
| `/etc/wireguard/wg0.conf` | WireGuard exit node |
| `/etc/wireguard/private.key` | Приватный ключ |
| `/etc/wireguard/public.key` | Публичный ключ (для RU-VPN peer) |

---

## Типичные проблемы

### VPN не подключается, сразу разрывается (NO_PROPOSAL_CHOSEN)
Причина: `left=%defaultroute` в ikev2.conf привязан к wg0.  
Решение: `docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=<RU_IP>/" /etc/ipsec.d/ikev2.conf && docker exec ipsec-vpn-server ipsec restart`

### VPN подключается, но страницы не загружаются
Причина: MSS clamp отсутствует или FORWARD chain блокирует трафик через wg0.  
Решение: добавить FORWARD правила для wg0 и MSS clamp (см. выше).

### VPN подключается, но IP остаётся российским (не латвийский)
Причина: MASQUERADE для 192.168.43.0/24 настроен на eth0, а не wg0.  
Решение: `iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE`

### SSH оборвался после запуска WireGuard
Причина: нет PostUp правила для сохранения SSH.  
Решение: через панель хостинга добавить в wg0.conf:  
`PostUp = ip rule add from <RU_IP> table main`

### После перезагрузки VPN клиенты не выходят в интернет
Причина: iptables правила не переживают перезагрузку.  
Решение: проверить что `vpn-iptables-fix.service` включён (`systemctl status vpn-iptables-fix`).
