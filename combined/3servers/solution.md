# Solution: 3 сервера — SOCKS5 + IKEv2 с общей LAT exit нодой

## Схема

```
[Browser / Zero Omega]     [Device: iPhone/macOS/Windows]
         │                           │
         │ SOCKS5 :43473             │ IKEv2 :500/:4500
         ▼                           ▼
[RU-SOCKS]  10.0.0.2          [RU-VPN]  10.0.0.3
      │                              │
      └──────── WireGuard ───────────┘
                     │
            [LAT сервер]  10.0.0.1
            (2 peers: SOCKS + VPN)
                     │
              MASQUERADE (NAT)
                     │
                  Интернет
             (виден латвийский IP)
```

## Адресация WireGuard

| Сервер | WG IP | Роль |
|--------|-------|------|
| LAT | 10.0.0.1/24 | exit node, ListenPort 51820 |
| RU-SOCKS | 10.0.0.2/32 | SOCKS5 прокси → LAT |
| RU-VPN | 10.0.0.3/32 | IKEv2 сервер → LAT |

---

## Порядок настройки

> **Важно:** Оба RU сервера независимы. Можно настраивать параллельно.

### Шаг 1 — LAT сервер (сначала)

```fish
# На LAT сервере
# Вставить публичные ключи RU серверов ПОСЛЕ их настройки
# Первый запуск — заглушки, потом обновить
fish setup-lat-shared.fish
```

LAT выдаст свой публичный ключ → скопировать для обоих RU серверов.

### Шаг 2a — RU-SOCKS сервер

```fish
# Вставить LAT_PUBLIC_KEY и LAT_IP
fish setup-ru-socks.fish
```

Скрипт выдаст публичный ключ RU-SOCKS → добавить на LAT.

### Шаг 2b — RU-VPN сервер (параллельно с 2a)

```fish
# Вставить LAT_PUBLIC_KEY и LAT_IP
fish setup-ru-vpn.fish
```

Скрипт выдаст публичный ключ RU-VPN → добавить на LAT.

### Шаг 3 — Добавить peers на LAT

На LAT сервере:
```fish
# Добавить RU-SOCKS
wg set wg0 peer <RU_SOCKS_PUBLIC_KEY> allowed-ips 10.0.0.2/32

# Добавить RU-VPN
wg set wg0 peer <RU_VPN_PUBLIC_KEY> allowed-ips 10.0.0.3/32

# Сохранить
wg-quick save wg0
```

### Шаг 4 — Добавить VPN клиента

На RU-VPN:
```fish
docker exec -it ipsec-vpn-server ikev2.sh
# → 1) Add a new client → vpnclient
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
# RU-SOCKS
PublicKey = <RU-SOCKS публичный ключ>
AllowedIPs = 10.0.0.2/32

[Peer]
# RU-VPN
PublicKey = <RU-VPN публичный ключ>
AllowedIPs = 10.0.0.3/32
```

### RU-SOCKS `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <RU-SOCKS приватный ключ>
PostUp = ip rule add from <RU_SOCKS_IP> table main
PostDown = ip rule del from <RU_SOCKS_IP> table main

[Peer]
PublicKey = <LAT публичный ключ>
Endpoint = <LAT_IP>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

### RU-VPN `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.3/24
PrivateKey = <RU-VPN приватный ключ>
PostUp = ip rule add from <RU_VPN_IP> table main
PostDown = ip rule del from <RU_VPN_IP> table main

[Peer]
PublicKey = <LAT публичный ключ>
Endpoint = <LAT_IP>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

---

## Преимущества топологии 3 серверов

| Аспект | Значение |
|--------|---------|
| Один LAT сервер | Экономия: один VPS вместо двух |
| Независимые RU серверы | Отказ одного не затрагивает другой |
| Один внешний IP | Оба сервиса выходят через один латвийский IP |
| Масштабируемость | Легко добавить ещё один peer на LAT |

## Диагностика

```fish
# На LAT — видны ли оба peer?
wg show
# Ожидаем: два peer с последним handshake

# На RU-SOCKS
wg show ; curl -s https://ifconfig.me  # должен быть LAT IP

# На RU-VPN
wg show
docker exec ipsec-vpn-server ipsec status | grep -E "total|interface:|local:"
curl -s https://ifconfig.me  # LAT IP
```
