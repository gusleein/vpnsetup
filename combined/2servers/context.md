# Context: 2 сервера — SOCKS5 + IKEv2 на одном RU сервере

## Схема топологии

```
[Browser / Zero Omega]  ──── SOCKS5 :43473 ──┐
                                               │
[Device: iPhone/macOS/Windows] ─ IKEv2 :500 ──┤
                                               ▼
                                      [RU сервер]
                                      ├── 3proxy (SOCKS5 :43473)
                                      ├── Libreswan/Docker (IKEv2 :500/:4500)
                                      └── WireGuard клиент
                                          wg0: 10.0.0.2
                                               │
                                        WireGuard UDP :51820
                                               │
                                      [LAT сервер]
                                      wg0: 10.0.0.1
                                      Один [Peer]: RU
                                      MASQUERADE → Internet
                                               │
                                            Internet
                                      (виден латвийский IP)
```

---

## Почему два сервера, а не три или четыре

Минимальная конфигурация. Один RU VPS обслуживает оба сценария:

- Через SOCKS5 → выходят через LAT
- Личные устройства через IKEv2 → выходят через LAT

**Подходит когда:**

- Минимум затрат (2 VPS вместо 3-4)
- Нагрузка небольшая (несколько человек)
- Не критична изоляция сервисов

**Недостаток:** при проблемах с одним сервисом (например, Docker контейнер ломает iptables) потенциально затрагивается и SOCKS5.

---

## Адресация WireGuard

```
10.0.0.1/24  — LAT (ListenPort 51820, один [Peer])
10.0.0.2/24  — RU  (единый сервер SOCKS5 + VPN)
```

VPN клиенты получают адреса из пула: `192.168.43.10–192.168.43.250`

---

## Совместимость 3proxy и IKEv2 на одном сервере

3proxy и Libreswan (IKEv2) **не конфликтуют**:


| Сервис          | Протокол | Порт                    |
| --------------- | -------- | ----------------------- |
| 3proxy          | TCP      | 43473                   |
| Libreswan IKEv2 | UDP      | 500                     |
| Libreswan NAT-T | UDP      | 4500                    |
| WireGuard       | UDP      | 51820 (исходящий к LAT) |
| SSH             | TCP      | 22                      |


Каждый слушает разные порты/протоколы — никаких конфликтов.

---

## Критические детали: Docker IKEv2

### --network=host обязателен

С bridge сетью (`-p 500:500/udp`) `docker-proxy` перехватывает UDP в userspace.  
IKEv2 ответы уходят через WireGuard в Латвию вместо прямого ответа клиенту.  
Клиент подключается к российскому IP, получает ответ от латвийского → отклоняет.

С `--network=host` Libreswan слушает напрямую на `eth0: <RU_IP>:500`.  
Правило `ip rule add from <RU_IP> table main` гарантирует выход IKEv2 ответов через `eth0`.

### Фикс left=%defaultroute (обязателен после каждого первого старта)

При старте контейнера Libreswan определяет интерфейс через default route.  
Default route = `wg0` (в Латвию) → Libreswan привязывается к `wg0` (10.0.0.2).

`ikev2-cp connection: local: 10.0.0.2, interface: wg0` → клиент получает `NO_PROPOSAL_CHOSEN`.

Скрипт автоматически исправляет:

```bash
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=<RU_IP>/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
```

Изменение **персистентно** — файл находится в смонтированном volume (`~/ikev2-vpn-data`).

### Сброс FORWARD chain (обязателен)

Контейнер при каждом старте перезаписывает FORWARD chain и добавляет `DROP all`.  
WireGuard правила (wg0) стираются → трафик VPN клиентов блокируется.

Скрипт создаёт systemd сервис `vpn-iptables-fix.service` который после старта восстанавливает:

```bash
# Перед DROP правилом контейнера
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT

# NAT для VPN клиентов (через wg0, не eth0!)
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE

# MSS clamp: eth0(1500) → WG(1420) → IKEv2(~1360)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

### VPN_PUBLIC_IP — почему важен и его ограничение

В `vpn.env` обязательно:

```
VPN_PUBLIC_IP=<RU_IP>
```

Без него контейнер автоопределит латвийский IP через `curl ifconfig.me` (весь трафик идёт через WireGuard). IKEv2 сертификат будет выписан на неправильный IP.

**Ограничение:** если `~/ikev2-vpn-data/ikev2.conf` уже существует — `VPN_PUBLIC_IP` **не применяется** к IKEv2.  
Подробнее: [hwdsl2 advanced-usage](https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip)

При повторном запуске скрипта или наличии старого volume:

```bash
# Вариант 1: сохранить клиентские сертификаты
rm ~/ikev2-vpn-data/ikev2.conf
# пересоздать контейнер → IKEv2 перегенерируется

# Вариант 2: полный сброс
docker exec ipsec-vpn-server ikev2.sh
# → 6) Remove IKEv2
```

В обоих случаях `left=` исправляется через sed после перезапуска (скрипт делает это автоматически).

### VPN_IKEV2_ONLY=yes

Добавлено в `vpn.env`. Отключает L2TP и XAuth (Cisco IPsec), оставляет только IKEv2:

- Меньше поверхность атаки
- xl2tpd не запускается в контейнере
- iptables правила контейнера проще

---

## Критические детали: 3proxy SOCKS5

### auth none — обязательно

Chrome и все Chromium-браузеры **не поддерживают** аутентификацию через SOCKS5.  
При `auth strong` — браузер получает 407 и показывает "SOCKS5 authentication not supported".

В `/etc/3proxy/conf.cfg`:

```
auth none
allow *
socks -p43473
```

### SSH при WireGuard AllowedIPs = 0.0.0.0/0

WireGuard захватывает весь трафик → SSH тоже уходит в туннель → SSH обрывается.

Решение в `/etc/wireguard/wg0.conf`:

```
PostUp = ip rule add from <RU_IP> table main
PostDown = ip rule del from <RU_IP> table main
```

Ядру: "трафик ОТ `<RU_IP>` → основная таблица маршрутизации, не WireGuard".  
SSH отвечает со своего IP → соединение сохраняется.

---

## Взаимодействие сервисов при перезагрузке

```
Boot
 │
 ├─ systemd: wg-quick@wg0  → WireGuard запускается (wg0 up)
 │   └─ PostUp: ip rule add from <RU_IP> table main
 │
 ├─ systemd: docker         → Docker daemon запускается
 │   └─ docker: ipsec-vpn-server --restart=always → контейнер стартует
 │       └─ run.sh: iptables FLUSH FORWARD → WG правила уничтожены!
 │
 └─ systemd: vpn-iptables-fix (After=docker, ExecStartPre: sleep 45)
     └─ 45 секунд ожидания (контейнер успевает завершить setup)
     └─ vpn-iptables-fix.sh: восстановить WG FORWARD правила ✓
```

3proxy через systemd запускается независимо и не влияет на iptables.

---

## Файлы и их назначение

### RU сервер


| Файл                                           | Назначение                         |
| ---------------------------------------------- | ---------------------------------- |
| `/etc/wireguard/wg0.conf`                      | WireGuard туннель к LAT (10.0.0.2) |
| `/etc/wireguard/private.key`                   | WG приватный ключ (не передавать!) |
| `/etc/wireguard/public.key`                    | WG публичный ключ (для LAT peer)   |
| `/etc/3proxy/3proxy.cfg`                       | Точка входа 3proxy                 |
| `/etc/3proxy/conf.cfg`                         | Порт 43473, auth none              |
| `/var/log/3proxy/`                             | Логи SOCKS5 соединений             |
| `~/vpn.env`                                    | VPN_PUBLIC_IP, VPN_IKEV2_ONLY=yes  |
| `~/ikev2-vpn-data/`                            | Volume: сертификаты IKEv2          |
| `~/ikev2-vpn-data/ikev2.conf`                  | Конфиг соединения (правим left=)   |
| `/usr/local/bin/vpn-iptables-fix.sh`           | Восстановление iptables правил     |
| `/etc/systemd/system/vpn-iptables-fix.service` | Systemd для персистентности        |


### LAT сервер


| Файл                         | Назначение                   |
| ---------------------------- | ---------------------------- |
| `/etc/wireguard/wg0.conf`    | WG exit node, один [Peer]    |
| `/etc/wireguard/private.key` | Приватный ключ               |
| `/etc/wireguard/public.key`  | Публичный ключ (для RU peer) |


---

## Типичные проблемы

### SSH оборвался после запуска WireGuard

Нет PostUp правила. Через панель хостинга добавить в `wg0.conf`:

```
PostUp = ip rule add from <RU_IP> table main
```

### 3proxy: браузер показывает "SOCKS5 authentication not supported"

`auth strong` в конфиге. Исправить на `auth none` + `allow *`.

### VPN: сразу отключается (NO_PROPOSAL_CHOSEN)

`left=%defaultroute` привязан к `wg0`. Исправить:

```bash
docker exec ipsec-vpn-server grep "^  left" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server sed -i "s/left=.*/left=<RU_IP>/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
```

### VPN: подключается, страницы не загружаются

FORWARD chain заблокирован или нет MASQUERADE на wg0:

```bash
iptables -L FORWARD -n -v | head -10
iptables -t nat -L POSTROUTING -n -v | grep wg0
# Если нет правил:
/usr/local/bin/vpn-iptables-fix.sh
```

### VPN: IP показывает российский, не латвийский

MASQUERADE для VPN клиентов настроен на `eth0` вместо `wg0`:

```bash
# Проверить:
iptables -t nat -L POSTROUTING -n -v | grep "192.168.43"
# Должно быть: ... out: wg0 ... 192.168.43.0/24 ... MASQUERADE
```

### После перезагрузки VPN клиенты без интернета

Правила не восстановились. Проверить:

```bash
systemctl status vpn-iptables-fix
# Если не запустился — запустить вручную:
/usr/local/bin/vpn-iptables-fix.sh
```

