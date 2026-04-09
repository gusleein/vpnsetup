# Solution: 2 сервера — SOCKS5 + IKEv2 на одном RU сервере

## Схема

```
[Browser / Zero Omega]  ────── SOCKS5 :43473 ──┐
                                                  │
[iPhone / macOS / Windows]  ── IKEv2 :500/:4500 ┤
                                                  │
                                          [RU сервер]
                                          ├── 3proxy (SOCKS5)
                                          ├── Docker IKEv2 (--network=host)
                                          └── WireGuard клиент (10.0.0.2)
                                                  │
                                          WireGuard UDP :51820
                                                  │
                                          [LAT сервер]
                                          └── WireGuard exit node
                                              └── MASQUERADE (NAT)
                                                  │
                                               Интернет
                                          (виден латвийский IP)
```

## Адресация

| Компонент | IP |
|-----------|---|
| LAT WireGuard | 10.0.0.1/24 |
| RU WireGuard | 10.0.0.2/24 |
| VPN клиенты | 192.168.43.10–250 |

---

## Порядок настройки

### Шаг 1 — LAT сервер

```fish
fish setup-lat.fish
```

Запомни публичный ключ LAT.

### Шаг 2 — RU сервер (с SOCKS5 + IKEv2)

Вставить в `setup-ru-combined.fish`:
- `LAT_PUBLIC_KEY` — ключ с Шага 1
- `LAT_IP` — IP LAT сервера

```fish
fish setup-ru-combined.fish
```

Во время скрипта будет пауза для добавления ключа на LAT.

### Шаг 3 — Добавить VPN клиента

```fish
docker exec -it ipsec-vpn-server ikev2.sh
# → 1) Add a new client → vpnclient
```

### Шаг 4 — Скопировать профиль

```fish
# Со своего Mac:
scp root@<RU_IP>:~/ikev2-vpn-data/vpnclient.mobileconfig ./
# iOS/macOS: открыть .mobileconfig
# Windows:   использовать vpnclient.p12
# Android:   использовать vpnclient.sswan
```

---

## Конфиги

### LAT `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/24
PrivateKey = <LAT приватный ключ>
ListenPort = 51820
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# RU сервер (SOCKS5 + IKEv2)
PublicKey = <RU публичный ключ>
AllowedIPs = 10.0.0.2/32
```

### RU `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <RU приватный ключ>
PostUp = ip rule add from <RU_IP> table main
PostDown = ip rule del from <RU_IP> table main

[Peer]
PublicKey = <LAT публичный ключ>
Endpoint = <LAT_IP>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### RU `~/vpn.env`

```
VPN_PUBLIC_IP=<RU_IP>
VPN_IPSEC_PSK=<случайная строка>
VPN_USER=vpnuser
VPN_PASSWORD=<случайный пароль>
```

---

## Важные детали реализации

### Почему --network=host для Docker

С bridge (`-p 500:500/udp`) IKEv2 не работает с WireGuard.
`docker-proxy` перехватывает UDP в userspace, и ответы IKEv2 уходят через WireGuard на латвийский IP.
Клиент подключается к российскому IP → получает ответ от латвийского → отклоняет.

### Почему фиксируем left=%defaultroute

После старта контейнера Libreswan привязывается к wg0 (default route = LAT через WireGuard).
`ikev2-cp` connection: `local: 10.0.0.2`, `interface: wg0` → клиент получает NO_PROPOSAL_CHOSEN.

Фикс (делается автоматически скриптом):
```bash
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=<RU_IP>/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
```

### Порты и сервисы на RU сервере

| Порт | Сервис |
|------|--------|
| 43473/tcp | 3proxy SOCKS5 |
| 500/udp | IKEv2 (Libreswan) |
| 4500/udp | IKEv2 NAT-T (Libreswan) |
| 51820/udp | WireGuard (исходящий к LAT) |
| 22/tcp | SSH |

### 3proxy и IKEv2 не конфликтуют

- 3proxy: только SOCKS5 прокси, принимает TCP соединения и проксирует их
- IKEv2: UDP 500/4500, обрабатывается Libreswan напрямую
- Оба сервиса полностью независимы

---

## Диагностика

```fish
# Полный статус
echo "=== WireGuard ===" ; wg show
echo "=== External IP ===" ; curl -s https://ifconfig.me
echo "=== 3proxy ===" ; systemctl status 3proxy --no-pager
echo "=== IKEv2 ===" ; docker exec ipsec-vpn-server ipsec status | grep -E "total|interface:|local:|ESTABLISHED"
echo "=== FORWARD ===" ; iptables -L FORWARD -n -v | head -8
echo "=== NAT ===" ; iptables -t nat -L POSTROUTING -n -v | grep -E "43|wg|MASQ"
echo "=== MANGLE ===" ; iptables -t mangle -L FORWARD -n -v

# Перезапуск сервисов (без пересоздания контейнера)
systemctl restart wg-quick@wg0
systemctl restart 3proxy
docker exec ipsec-vpn-server ipsec restart

# После рестарта WireGuard нужно восстановить iptables
/usr/local/bin/vpn-iptables-fix.sh
```

---

## Преимущества и недостатки топологии 2 серверов

| | Значение |
|---|---|
| ✅ Минимум серверов | 2 VPS вместо 3-4 |
| ✅ Один внешний IP для клиентов | Простая настройка |
| ⚠️ Нагрузка на один RU сервер | SOCKS5 + IKEv2 вместе |
| ⚠️ Нет изоляции | Проблема с одним сервисом затрагивает оба |
