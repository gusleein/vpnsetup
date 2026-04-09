# Context: 3 сервера — SOCKS5 + IKEv2 с общей LAT exit нодой

## Схема топологии

```
[Browser / Zero Omega]          [Device: iPhone/macOS/Windows]
         │                                   │
         │ SOCKS5 :43473                     │ IKEv2 :500/:4500
         ▼                                   ▼
[RU-SOCKS]                            [RU-VPN]
wg0: 10.0.0.2                         wg0: 10.0.0.3
3proxy (SOCKS5 сервер)                Docker IKEv2 (--network=host)
         │                                   │
         └──────────── WireGuard ────────────┘
                             │
                      [LAT сервер]
                      wg0: 10.0.0.1
                      Два [Peer]: SOCKS + VPN
                      MASQUERADE → Internet
                             │
                          Internet
                    (виден латвийский IP)
```

---

## Почему три сервера, а не два или четыре

### Vs 4 сервера (полная изоляция)
Топология 4 серверов: RU-SOCKS → LAT-1, RU-VPN → LAT-2 (два независимых LAT сервера).  
Три сервера экономят один VPS при этом сохраняя независимость RU серверов между собой.  
Отказ RU-SOCKS не влияет на RU-VPN и наоборот.

### Vs 2 сервера (всё на одном RU)
При двух серверах 3proxy и IKEv2 работают на одной машине.  
При трёх серверах каждый сервис на своём — изолированнее, легче масштабировать.

---

## Адресация WireGuard

```
10.0.0.1/24  — LAT (ListenPort 51820, два [Peer] блока)
10.0.0.2/32  — RU-SOCKS (AllowedIPs на LAT)
10.0.0.3/32  — RU-VPN   (AllowedIPs на LAT)
```

Оба RU сервера подключаются к **одному** LAT, но не видят друг друга.  
LAT маршрутизирует трафик каждого независимо.

---

## Как работает MASQUERADE с двумя peers

На LAT одно правило:
```
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

Оно применяется ко всему трафику, приходящему через wg0 — и от RU-SOCKS (10.0.0.2), и от RU-VPN (10.0.0.3).  
Оба сервера выходят в интернет с одним латвийским IP.

---

## Критические детали RU-VPN сервера

Всё то же, что в отдельном VPN_ikev2_setup, применяется и здесь:

### Docker --network=host (обязателен)
С bridge сетью (`-p 500:500/udp`) `docker-proxy` перехватывает UDP в userspace.  
IKEv2 ответы уходят через WireGuard в Латвию вместо прямого ответа клиенту.  
Клиент подключается к российскому IP, получает ответ от латвийского → отклоняет.

### Фикс left=%defaultroute (обязателен)
После старта контейнера Libreswan привязывается к `wg0` (default route = LAT).  
`ikev2-cp connection: local: 10.0.0.3, interface: wg0` → `NO_PROPOSAL_CHOSEN`.

```bash
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=<RU_VPN_IP>/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
```

Изменение **персистентно** — файл в смонтированном volume.

### Сброс FORWARD chain (обязателен)
Контейнер при каждом старте перезаписывает FORWARD chain и добавляет `DROP all`.  
WireGuard правила (wg0) стираются. Нужно восстановить после старта:

```bash
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
```

Для персистентности после перезагрузки — systemd сервис `vpn-iptables-fix.service`.

### VPN_PUBLIC_IP и его ограничение
В `vpn.env` обязательно задать:
```
VPN_PUBLIC_IP=<RU_VPN_IP>
```

Иначе контейнер автоопределит латвийский IP (трафик идёт через WireGuard).  
IKEv2 сертификат будет выписан на латвийский IP → клиенты не смогут подключиться.

**Ограничение:** если `~/ikev2-vpn-data/ikev2.conf` уже существует, `VPN_PUBLIC_IP` **не применяется** к IKEv2. В этом случае `left=` исправляется через `sed` (скрипт делает это автоматически).  
Подробнее: [hwdsl2 advanced-usage](https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip)

### VPN_IKEV2_ONLY=yes
Отключает L2TP и XAuth, оставляет только IKEv2.  
Уменьшает поверхность атаки, убирает xl2tpd из контейнера.

### MSS Clamp (обязателен)
Цепочка MTU: `eth0(1500) → WireGuard(1420) → IKEv2(~1360)`  
Без MSS clamp большие TCP пакеты теряются → страницы не загружаются.

---

## Критические детали RU-SOCKS сервера

### 3proxy: auth none
Chrome и все Chromium-браузеры не поддерживают аутентификацию через SOCKS5.  
В `conf.cfg` должно быть `auth none` + `allow *`.

### SSH сохранение при AllowedIPs = 0.0.0.0/0
WireGuard захватывает весь трафик включая SSH. Решение:
```
PostUp = ip rule add from <RU_SOCKS_IP> table main
PostDown = ip rule del from <RU_SOCKS_IP> table main
```
Ядру: "трафик ОТ собственного IP сервера → основная таблица маршрутизации, не WireGuard".

---

## Порядок инициализации (важен)

```
1. LAT запускается (генерирует ключи, настраивает WG)
2. RU-SOCKS запускается (получает LAT ключ, поднимает WG + 3proxy)
3. RU-VPN запускается (получает LAT ключ, поднимает WG + Docker IKEv2)
4. Ключи RU серверов добавляются на LAT как peers
5. WireGuard туннели устанавливаются (handshake)
```

RU серверы можно настраивать параллельно (шаги 2 и 3 независимы).

---

## Файлы и сервисы

### LAT сервер
| Файл | Назначение |
|------|-----------|
| `/etc/wireguard/wg0.conf` | WG exit node, 2 peer блока |
| `/etc/wireguard/private.key` | Приватный ключ |
| `/etc/wireguard/public.key` | Публичный ключ (нужен обоим RU) |

### RU-SOCKS сервер
| Файл | Назначение |
|------|-----------|
| `/etc/wireguard/wg0.conf` | WG туннель до LAT (10.0.0.2) |
| `/etc/3proxy/3proxy.cfg` | Точка входа 3proxy |
| `/etc/3proxy/conf.cfg` | Порт 43473, auth none |
| `/var/log/3proxy/` | Логи соединений |

### RU-VPN сервер
| Файл | Назначение |
|------|-----------|
| `/etc/wireguard/wg0.conf` | WG туннель до LAT (10.0.0.3) |
| `~/vpn.env` | VPN_PUBLIC_IP, VPN_IKEV2_ONLY=yes |
| `~/ikev2-vpn-data/` | Volume: сертификаты IKEv2 |
| `~/ikev2-vpn-data/ikev2.conf` | Конфиг соединения (правим left=) |
| `/usr/local/bin/vpn-iptables-fix.sh` | Восстановление iptables |
| `/etc/systemd/system/vpn-iptables-fix.service` | Systemd сервис |

---

## Типичные проблемы

### Туннель между RU и LAT не поднимается
- `wg show` на LAT: виден ли peer с нужным ключом?
- AllowedIPs на LAT: `10.0.0.2/32` для SOCKS, `10.0.0.3/32` для VPN
- Порт 51820/udp открыт на LAT?

### SOCKS не работает, но WG туннель поднят
- `systemctl status 3proxy` — запущен ли?
- Лог: `tail -f /var/log/3proxy/3proxy-*.log`
- Код 00004 в логах → проверить `auth none` в conf.cfg

### VPN не подключается (сразу разрывается)
- `docker exec ipsec-vpn-server ipsec status | grep "interface:|local:"`
- Должно быть `interface: eth0`, не `wg0`
- Если `wg0` → повторить фикс: `docker exec ipsec-vpn-server sed -i "s/left=.*/left=<IP>/" /etc/ipsec.d/ikev2.conf`

### VPN подключается, интернет не работает
- `iptables -L FORWARD -n -v | head -10` — есть ли ACCEPT для wg0?
- `iptables -t nat -L POSTROUTING -n -v | grep wg0` — есть ли MASQUERADE?
- Запустить: `/usr/local/bin/vpn-iptables-fix.sh`

### После перезагрузки VPN клиенты без интернета
- `systemctl status vpn-iptables-fix` — работает ли сервис?
- Сервис стартует через 45 секунд после Docker — нормально
