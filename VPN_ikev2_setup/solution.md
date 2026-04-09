# Solution: IKEv2 VPN → RU → WireGuard → LAT

## Схема

```
[iPhone / macOS / Windows / Android]
         │
         │ IKEv2/IPsec  UDP :500, :4500
         ▼
[RU-VPN сервер]  ←── клиенты видят этот IP
  └── Libreswan (Docker --network=host)
  └── WireGuard клиент (wg0: 10.0.0.3)
         │
         │ WireGuard туннель UDP :51820
         ▼
[LAT сервер]
  └── WireGuard exit node + MASQUERADE
         │
         ▼
    Интернет  ←── виден латвийский IP
```

---

## Порядок настройки

### Шаг 1 — LAT сервер

```fish
fish setup-lat.fish
```

Скрипт выведет публичный ключ LAT сервера — **скопируй его**.

### Шаг 2 — RU-VPN сервер

Вставить в `setup-ru-vpn.fish`:
- `LAT_PUBLIC_KEY` — ключ с Шага 1
- `LAT_IP` — IP LAT сервера

```fish
fish setup-ru-vpn.fish
```

Скрипт выведет публичный ключ RU-VPN и попросит добавить его на LAT.

### Шаг 3 — Добавить RU-VPN как peer на LAT

На LAT сервере:
```fish
wg set wg0 peer <RU_VPN_PUBLIC_KEY> allowed-ips 10.0.0.3/32
wg-quick save wg0
```

### Шаг 4 — Добавить VPN клиента

На RU-VPN сервере:
```fish
docker exec -it ipsec-vpn-server ikev2.sh
# Выбрать: 1) Add a new client
# Имя клиента: vpnclient (или любое другое)
```

### Шаг 5 — Скопировать профиль на устройство

```fish
# Со своего Mac/ПК:
scp root@<RU_VPN_IP>:~/ikev2-vpn-data/vpnclient.mobileconfig ./
# iOS/macOS: открыть .mobileconfig → установить профиль
# Windows:   использовать vpnclient.p12
# Android:   использовать vpnclient.sswan
```

---

## Конфиги

### RU-VPN `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.3/24
PrivateKey = <приватный ключ RU-VPN>
PostUp = ip rule add from <RU_VPN_IP> table main
PostDown = ip rule del from <RU_VPN_IP> table main

[Peer]
PublicKey = <публичный ключ LAT>
Endpoint = <LAT_IP>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### LAT `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/24
PrivateKey = <приватный ключ LAT>
ListenPort = 51820
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# RU-VPN сервер
PublicKey = <публичный ключ RU-VPN>
AllowedIPs = 10.0.0.3/32
```

### RU-VPN `~/vpn.env`

```
VPN_PUBLIC_IP=<RU_VPN_IP>
VPN_IPSEC_PSK=<случайная строка>
VPN_USER=vpnuser
VPN_PASSWORD=<случайный пароль>
```

---

## Диагностика

```fish
# WireGuard туннель живой?
wg show

# Внешний IP (должен быть латвийским)
curl -s https://ifconfig.me

# IKEv2 статус (есть ли подключения?)
docker exec ipsec-vpn-server ipsec status | grep -E "ESTABLISHED|total|interface:|local:"

# iptables правила в порядке?
iptables -L FORWARD -n -v | head -10
iptables -t nat -L POSTROUTING -n -v | grep -E "43|wg0"
iptables -t mangle -L FORWARD -n -v

# Логи контейнера
docker logs ipsec-vpn-server --tail 30

# Перезапуск IKEv2 (без пересоздания контейнера)
docker exec ipsec-vpn-server ipsec restart

# Полная диагностика
echo "=== WG ===" ; wg show
echo "=== ROUTES ===" ; ip route show
echo "=== IP RULES ===" ; ip rule list
echo "=== FORWARD ===" ; iptables -L FORWARD -n -v --line-numbers | head -20
echo "=== NAT ===" ; iptables -t nat -L POSTROUTING -n -v
echo "=== MANGLE ===" ; iptables -t mangle -L FORWARD -n -v
echo "=== IKEv2 ===" ; docker exec ipsec-vpn-server ipsec status | grep -E "total|ESTABLISHED|interface:|local:"
echo "=== PORTS ===" ; ss -ulnp | grep -E "500|4500"
```
