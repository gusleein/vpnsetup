# Solution: SOCKS5 Proxy → RU → WireGuard → LAT

## Схема

```
Браузер (Zero Omega / любой SOCKS5 клиент)
       │
       │ SOCKS5 :43473
       ▼
Российский сервер  ←─── внешний IP клиентам
  └── 3proxy (SOCKS5 сервер)
       │
       │ WireGuard UDP :51820 (зашифрованный туннель)
       │ 10.0.0.2 ──────────── 10.0.0.1
       ▼
Латвийский сервер
  └── WireGuard exit node + NAT (MASQUERADE)
       │
       │ Обычный HTTP/HTTPS
       ▼
    Интернет  ←─── виден латвийский IP
```

---

## Порядок настройки

### Шаг 1 — LAT сервер

```fish
# Вставить публичный ключ RU сервера в LAT скрипт (узнать после Шага 2)
# Первый запуск — LAT генерирует свои ключи
fish setup-lat.fish
```

Скрипт выведет **публичный ключ LAT сервера** — скопируй его для Шага 2.

### Шаг 2 — RU сервер

Вставить в `setup-ru.fish`:
- `LAT_PUBLIC_KEY` — ключ с Шага 1
- `LAT_IP` — IP латвийского сервера

```fish
fish setup-ru.fish
```

Скрипт выведет **публичный ключ RU сервера** — вставить в `setup-lat.fish` и перезапустить LAT (или добавить peer вручную).

### Шаг 3 — Добавить RU ключ на LAT

```fish
# На LAT сервере добавить peer вручную (если setup-lat.fish уже запускали)
wg set wg0 peer <RU_PUBLIC_KEY> allowed-ips 10.0.0.2/32
# Сохранить в конфиг
wg-quick save wg0
```

### Шаг 4 — Проверка туннеля

На RU сервере:
```fish
ping -c 3 10.0.0.1          # пинг до LAT через WireGuard
curl -s https://ifconfig.me  # должен показать латвийский IP
wg show                      # статус туннеля
```

### Шаг 5 — Настройка браузера (Zero Omega)

```
Protocol: SOCKS5
Server:   <IP российского сервера>
Port:     43473
```

---

## Конфиги

### RU `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <приватный ключ RU>
PostUp = ip rule add from <RU_IP> table main
PostDown = ip rule del from <RU_IP> table main

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
# RU-SOCKS сервер
PublicKey = <публичный ключ RU>
AllowedIPs = 10.0.0.2/32
```

### RU `/etc/3proxy/conf.cfg`

```
nscache 65536
nserver 8.8.8.8
nserver 8.8.4.4

log /var/log/3proxy/3proxy-%y%m%d.log D
rotate 60

auth none
allow *
socks -p43473
```

---

## Диагностика

```fish
# Полный статус (запускать на любом сервере)
wg show
echo "---"
ip addr show wg0
echo "---"
ip route
echo "---"
ping -c 3 10.0.0.1
echo "---"
curl -s https://ifconfig.me

# Логи 3proxy
tail -f /var/log/3proxy/3proxy-*.log

# Перезапуск сервисов
systemctl restart wg-quick@wg0
systemctl restart 3proxy

# Статус
systemctl status wg-quick@wg0 --no-pager
systemctl status 3proxy --no-pager
```

---

## Ограничение доступа к прокси (опционально)

Chrome не поддерживает SOCKS5 аутентификацию, поэтому прокси без пароля.
Ограничение через файрволл по IP:

```fish
ufw allow from 1.2.3.4 to any port 43473
ufw allow from 5.6.7.8 to any port 43473
ufw deny 43473
ufw enable
```
