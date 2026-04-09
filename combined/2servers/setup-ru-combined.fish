#!/usr/bin/env fish
# =============================================================================
# RU СЕРВЕР — SOCKS5 (3proxy) + IKEv2 VPN (Docker) на одной машине
# Топология: 2 сервера (один RU с SOCKS+VPN → LAT)
#
# Что делает этот скрипт:
#   1. WireGuard туннель до LAT
#   2. 3proxy — SOCKS5 прокси :43473
#   3. Docker IKEv2 VPN — nвместе с --network=host
#   4. iptables правила для VPN клиентов
#   5. Systemd сервис для персистентности iptables
#
# Переменные которые нужно заменить:
#   LAT_PUBLIC_KEY — публичный ключ LAT сервера
#   LAT_IP         — внешний IP LAT сервера
# =============================================================================

set LAT_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_LAT_СЕРВЕРА"
set LAT_IP "ВСТАВЬ_IP_LAT_СЕРВЕРА"
set WG_PORT "51820"
set SOCKS_PORT "43473"
set VPN_CLIENT_NAME "vpnclient"

echo "=== [0/8] Определение IP сервера ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
set RU_IP (ip -o -4 addr show dev $WG_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "Внешний интерфейс: $WG_IFACE"
echo "IP этого сервера: $RU_IP"

echo "=== [1/8] Установка зависимостей ==="
apt update
apt install wireguard docker.io -y
systemctl enable docker && systemctl start docker

echo "=== [2/8] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Публичный ключ RU сервера:                              ║"
echo "║  (добавить на LAT в wg0.conf)                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""
echo "На LAT сервере добавь peer:"
echo "  wg set wg0 peer $(cat /etc/wireguard/public.key) allowed-ips 10.0.0.2/32"
echo "  wg-quick save wg0"
echo ""
read -P "Нажми Enter когда добавишь ключ на LAT..."

echo "=== [3/8] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

printf '[Interface]\nAddress = 10.0.0.2/24\nPrivateKey = %s\nPostUp = ip rule add from %s table main\nPostDown = ip rule del from %s table main\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    $PRIVATE $RU_IP $RU_IP $LAT_PUBLIC_KEY $LAT_IP $WG_PORT \
    > /etc/wireguard/wg0.conf

echo "=== [4/8] Запуск WireGuard ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
sleep 3
echo "Внешний IP (должен быть латвийским):"
curl -s https://ifconfig.me
echo ""

echo "=== [5/8] Установка 3proxy (SOCKS5) ==="
set ARCH (dpkg --print-architecture)
if test "$ARCH" = "amd64"
    cd /tmp
    curl -LJO https://github.com/3proxy/3proxy/releases/download/0.9.5/3proxy-0.9.5.x86_64.deb 2>/dev/null
    if test -f 3proxy-0.9.5.x86_64.deb
        apt install -y ./3proxy-0.9.5.x86_64.deb
    else
        apt install git make gcc -y
        git clone https://github.com/3proxy/3proxy.git /tmp/3proxy-src
        cd /tmp/3proxy-src && make -f Makefile.Linux
        cp src/3proxy /usr/local/bin/ && chmod 755 /usr/local/bin/3proxy
    end
else
    apt install git make gcc -y
    git clone https://github.com/3proxy/3proxy.git /tmp/3proxy-src
    cd /tmp/3proxy-src && make -f Makefile.Linux
    cp src/3proxy /usr/local/bin/ && chmod 755 /usr/local/bin/3proxy
end

mkdir -p /etc/3proxy /var/log/3proxy
printf '#!/bin/3proxy\ninclude /etc/3proxy/conf.cfg\n' > /etc/3proxy/3proxy.cfg
printf 'nscache 65536\nnserver 8.8.8.8\nnserver 8.8.4.4\n\nlog /var/log/3proxy/3proxy-%%y%%m%%d.log D\nrotate 60\n\nauth none\nallow *\nsocks -p%s\n' $SOCKS_PORT > /etc/3proxy/conf.cfg
printf '[Unit]\nDescription=3proxy Proxy Server\nAfter=network.target\n\n[Service]\nExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg\nRestart=always\nRestartSec=5\nLimitNOFILE=65535\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/3proxy.service
systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy
echo "3proxy запущен:"
systemctl status 3proxy --no-pager -l

echo "=== [6/8] Запуск IKEv2 VPN контейнера ==="
mkdir -p ~/ikev2-vpn-data

# ВАЖНО: VPN_PUBLIC_IP не влияет на IKEv2, если ikev2.conf уже существует в volume
# Источник: https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip
# При повторном запуске или наличии старого volume — удали ikev2.conf:
#   rm ~/ikev2-vpn-data/ikev2.conf   (сертификаты клиентов сохранятся)
if test -f ~/ikev2-vpn-data/ikev2.conf
    echo "⚠ ikev2.conf уже существует — VPN_PUBLIC_IP не обновит IKEv2 сертификат."
    echo "  left= будет исправлен через sed ниже."
end

# VPN_PUBLIC_IP ОБЯЗАТЕЛЕН: без него контейнер автоопределит латвийский IP
# (т.к. WireGuard маршрутизирует трафик через LAT)
# VPN_IKEV2_ONLY=yes — только IKEv2, L2TP и XAuth отключены
printf 'VPN_PUBLIC_IP=%s\nVPN_IPSEC_PSK=%s\nVPN_USER=vpnuser\nVPN_PASSWORD=%s\nVPN_IKEV2_ONLY=yes\n' \
    $RU_IP \
    (openssl rand -base64 16 | tr -d '=+/') \
    (openssl rand -base64 12 | tr -d '=+/') \
    > ~/vpn.env

echo "vpn.env создан (VPN_PUBLIC_IP=$RU_IP)"

# --network=host ОБЯЗАТЕЛЕН для IKEv2:
# С bridge (-p 500:500/udp) ответы IKEv2 уходят через WireGuard в Латвию.
# Клиент подключается к российскому IP, но ответ получает от латвийского → отказ.
docker run \
    --name ipsec-vpn-server \
    --env-file ~/vpn.env \
    --restart=always \
    --network=host \
    -v ~/ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

echo "Ждём 40 секунд пока контейнер настроит IKEv2..."
sleep 40
docker logs --tail 10 ipsec-vpn-server

echo "=== [7/8] Критические исправления после старта контейнера ==="

# Исправление 1: left=%defaultroute → реальный IP
# Без этого Libreswan привязывается к wg0 (10.0.0.2) вместо eth0 (RU_IP)
# и возвращает NO_PROPOSAL_CHOSEN всем клиентам
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=$RU_IP/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
sleep 5
echo "Проверка привязки IKEv2 к eth0:"
docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:" | head -3

# Исправление 2: iptables для трафика VPN клиентов через wg0
# Контейнер сбрасывает FORWARD chain → теряются wg0 правила
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT
# MASQUERADE для VPN клиентов (идут через wg0, не eth0)
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE
# MSS clamp: обязателен для nested VPN (IKEv2 поверх WireGuard)
# Без него большие пакеты теряются и страницы не загружаются
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "=== [8/8] Персистентность iptables правил ==="
# Systemd сервис восстанавливает правила после каждой перезагрузки
# (контейнер при каждом старте сбрасывает FORWARD chain)
printf '#!/bin/bash\n# Восстанавливаем WireGuard FORWARD правила после старта контейнера\niptables -I FORWARD 1 -i wg0 -j ACCEPT\niptables -I FORWARD 2 -o wg0 -j ACCEPT\niptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE\niptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n' \
    > /usr/local/bin/vpn-iptables-fix.sh
chmod +x /usr/local/bin/vpn-iptables-fix.sh

printf '[Unit]\nDescription=Fix iptables for IKEv2 VPN over WireGuard\nAfter=docker.service wg-quick@wg0.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStartPre=/bin/sleep 45\nExecStart=/usr/local/bin/vpn-iptables-fix.sh\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/vpn-iptables-fix.service

systemctl daemon-reload
systemctl enable vpn-iptables-fix.service

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   НАСТРОЙКА ЗАВЕРШЕНА                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Добавить VPN клиента:                                       ║"
echo "║    docker exec -it ipsec-vpn-server ikev2.sh                ║"
echo "║    → 1) Add a new client → vpnclient                        ║"
echo "║                                                              ║"
echo "║  Скопировать профиль:                                        ║"
echo "║    scp root@$RU_IP:~/ikev2-vpn-data/vpnclient.mobileconfig ./ ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "=== WireGuard ==="
wg show
echo ""
echo "=== 3proxy ==="
systemctl status 3proxy --no-pager -l
echo ""
echo "=== IKEv2 ==="
docker exec ipsec-vpn-server ipsec status | grep -E "total|interface:|local:"
echo ""
echo "=== Внешний IP (должен быть латвийский) ==="
curl -s https://ifconfig.me
echo ""
echo "Настройки для клиентов:"
echo "  SOCKS5:  $RU_IP:$SOCKS_PORT (Zero Omega / браузер)"
echo "  IKEv2:   $RU_IP (сертификат из ~/ikev2-vpn-data/)"
echo ""
