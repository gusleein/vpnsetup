# VPN Setup

Набор скриптов и документации для построения приватной сети обхода блокировок.

Общая идея: российский сервер принимает трафик (SOCKS5 прокси или IKEv2 VPN),
перенаправляет его через WireGuard туннель на латвийский exit node,
откуда трафик выходит в интернет с латвийским IP.

```
Клиент → [RU сервер] → WireGuard → [LAT сервер] → Интернет
```

---

## Быстрый старт

Выбери топологию под свои нужды:

| Топология | Серверов | Для кого |
|-----------|----------|---------|
| [SOCKS5 proxy](#1-socks5-proxy) | 2 | Браузер через Zero Omega |
| [IKEv2 VPN](#2-ikev2-vpn) | 2 | Личные устройства (iOS/macOS/Windows) |
| [3 сервера](#3-три-сервера--общий-lat) | 3 | SOCKS5 + VPN, независимые RU серверы |
| [2 сервера](#4-два-сервера--всё-на-одном-ru) | 2 | SOCKS5 + VPN, один RU сервер |

Для каждой топологии: заполни переменные в скриптах → запусти LAT → запусти RU.

---

## Требования

- **Серверы:** Ubuntu 22.04+ LTS
- **Shell:** `fish` (скрипты написаны под fish)
- **RU-VPN:** Docker установлен или установится скриптом
- **Доступ:** root SSH на всех серверах
- **Порты открыты на LAT:** `51820/udp` (WireGuard)
- **Порты открыты на RU-SOCKS:** `43473/tcp` (SOCKS5)
- **Порты открыты на RU-VPN:** `500/udp`, `4500/udp` (IKEv2)

---

## Топологии

### 1. SOCKS5 Proxy

```
Браузер (Zero Omega) → SOCKS5 :43473 → [RU-SOCKS] → WireGuard → [LAT] → Интернет
```

**Папка:** [`SOCKS5_proxy_setup/`](SOCKS5_proxy_setup/)

| Файл | Назначение |
|------|-----------|
| `setup-lat.fish` | Настройка LAT сервера |
| `setup-ru.fish` | Настройка RU-SOCKS сервера |
| `context.md` | Почему именно так устроено |
| `solution.md` | Пошаговое руководство |

**Порядок запуска:**
```fish
# 1. На LAT сервере
fish setup-lat.fish    # → сохрани публичный ключ

# 2. На RU сервере (вставить LAT_PUBLIC_KEY и LAT_IP)
fish setup-ru.fish

# 3. Добавить RU ключ на LAT
wg set wg0 peer <RU_PUBLIC_KEY> allowed-ips 10.0.0.2/32
wg-quick save wg0
```

**Настройка браузера (Zero Omega):**
```
Protocol: SOCKS5
Server:   <RU_IP>
Port:     43473
```

---

### 2. IKEv2 VPN

```
iPhone/macOS/Windows → IKEv2 :500/:4500 → [RU-VPN] → WireGuard → [LAT] → Интернет
```

**Папка:** [`VPN_ikev2_setup/`](VPN_ikev2_setup/)

| Файл | Назначение |
|------|-----------|
| `setup-lat.fish` | Настройка LAT сервера |
| `setup-ru-vpn.fish` | Настройка RU-VPN сервера |
| `context.md` | Все критические проблемы и решения |
| `solution.md` | Пошаговое руководство |

**Порядок запуска:**
```fish
# 1. На LAT сервере
fish setup-lat.fish    # → сохрани публичный ключ

# 2. На RU-VPN сервере (вставить LAT_PUBLIC_KEY и LAT_IP)
fish setup-ru-vpn.fish

# 3. Добавить VPN клиента
docker exec -it ipsec-vpn-server ikev2.sh
# → 1) Add a new client → vpnclient

# 4. Скопировать профиль на устройство
scp root@<RU_IP>:~/ikev2-vpn-data/vpnclient.mobileconfig ./
```

> **Важно:** скрипт использует `--network=host` для Docker и автоматически исправляет
> `left=%defaultroute` в `ikev2.conf`. Подробности — в `context.md`.

---

### 3. Три сервера — общий LAT

```
[Browser] → SOCKS5 → [RU-SOCKS] ──┐
                                    ├── WireGuard → [LAT] → Интернет
[Device]  → IKEv2  → [RU-VPN]  ──┘
```

**Папка:** [`combined/3servers/`](combined/3servers/)

| Файл | Назначение |
|------|-----------|
| `setup-lat-shared.fish` | LAT с двумя peers (SOCKS + VPN) |
| `setup-ru-socks.fish` | RU-SOCKS (WG: 10.0.0.2) |
| `setup-ru-vpn.fish` | RU-VPN (WG: 10.0.0.3) |
| `context.md` | Архитектура и критические детали |
| `solution.md` | Пошаговое руководство |

**Порядок запуска:**
```fish
# 1. На LAT — генерация ключей (peers добавить после)
fish setup-lat-shared.fish

# 2a. На RU-SOCKS (независимо от RU-VPN)
fish setup-ru-socks.fish

# 2b. На RU-VPN (параллельно с 2a)
fish setup-ru-vpn.fish

# 3. Добавить оба peer на LAT
wg set wg0 peer <RU_SOCKS_KEY> allowed-ips 10.0.0.2/32
wg set wg0 peer <RU_VPN_KEY>   allowed-ips 10.0.0.3/32
wg-quick save wg0
```

---

### 4. Два сервера — всё на одном RU

```
[Browser] → SOCKS5 :43473 ──┐
                              ├── [RU] → WireGuard → [LAT] → Интернет
[Device]  → IKEv2  :500   ──┘
```

**Папка:** [`combined/2servers/`](combined/2servers/)

| Файл | Назначение |
|------|-----------|
| `setup-lat.fish` | Настройка LAT сервера |
| `setup-ru-combined.fish` | RU: 3proxy + IKEv2 + WireGuard |
| `context.md` | Архитектура, совместимость сервисов |
| `solution.md` | Пошаговое руководство |

**Порядок запуска:**
```fish
# 1. На LAT сервере
fish setup-lat.fish

# 2. На RU сервере (вставить LAT_PUBLIC_KEY и LAT_IP)
fish setup-ru-combined.fish

# 3. Добавить VPN клиента
docker exec -it ipsec-vpn-server ikev2.sh
# → 1) Add a new client → vpnclient
```

---

## Структура файлов

```
VPN_setup/
├── README.md                          ← этот файл
│
├── SOCKS5_proxy_setup/                ← топология 1: только SOCKS5
│   ├── context.md
│   ├── solution.md
│   ├── setup-lat.fish
│   └── setup-ru.fish
│
├── VPN_ikev2_setup/                   ← топология 2: только IKEv2 VPN
│   ├── context.md
│   ├── solution.md
│   ├── setup-lat.fish
│   └── setup-ru-vpn.fish
│
└── combined/
    ├── 3servers/                      ← топология 3: SOCKS+VPN, раздельные RU
    │   ├── context.md
    │   ├── solution.md
    │   ├── setup-lat-shared.fish      ← LAT с двумя peers
    │   ├── setup-ru-socks.fish
    │   └── setup-ru-vpn.fish
    │
    └── 2servers/                      ← топология 4: SOCKS+VPN, один RU
        ├── context.md
        ├── solution.md
        ├── setup-lat.fish
        └── setup-ru-combined.fish
```

---

## Адресация WireGuard (общая для всех топологий)

| Роль | WG IP | Используется в |
|------|-------|---------------|
| LAT exit node | `10.0.0.1/24` | все топологии |
| RU-SOCKS | `10.0.0.2/32` | SOCKS5, 3servers |
| RU-VPN | `10.0.0.3/32` | IKEv2, 3servers |
| RU-Combined | `10.0.0.2/24` | 2servers |

VPN клиенты (IKEv2): пул `192.168.43.10–192.168.43.250`

---

## Известные проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| SSH оборвался после WG | `AllowedIPs=0.0.0.0/0` без `PostUp` | Перезагрузить через панель, добавить `PostUp = ip rule add from <IP> table main` |
| SOCKS5: "auth not supported" | `auth strong` в 3proxy | Изменить на `auth none` + `allow *` |
| IKEv2: сразу отключается | `left=%defaultroute` привязан к wg0 | `docker exec ... sed -i "s/left=.*/left=<IP>/"` + `ipsec restart` |
| IKEv2: VPN есть, страницы не грузятся | FORWARD chain сброшен контейнером | Запустить `/usr/local/bin/vpn-iptables-fix.sh` |
| Показывает российский IP | MASQUERADE настроен на eth0, а не wg0 | `iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE` |

---

## Диагностика

```fish
# Туннель живой?
wg show

# Через какой IP выходим?
curl -s https://ifconfig.me

# 3proxy запущен?
systemctl status 3proxy --no-pager

# IKEv2 статус?
docker exec ipsec-vpn-server ipsec status | grep -E "total|ESTABLISHED|interface:|local:"

# iptables правила для VPN
iptables -L FORWARD -n -v | head -10
iptables -t nat -L POSTROUTING -n -v
iptables -t mangle -L FORWARD -n -v
```
