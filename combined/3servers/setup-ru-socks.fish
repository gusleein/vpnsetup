#!/usr/bin/env fish
# =============================================================================
# RU-SOCKS СЕРВЕР — SOCKS5 прокси с выходом через общий LAT сервер
# Топология: 3 сервера (RU-SOCKS + RU-VPN → shared LAT)
#
# Переменные которые нужно заменить перед запуском:
#   LAT_PUBLIC_KEY — публичный ключ LAT сервера
#   LAT_IP         — внешний IP LAT сервера
# =============================================================================

set LAT_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_LAT_СЕРВЕРА"
set LAT_IP "ВСТАВЬ_IP_LAT_СЕРВЕРА"
set WG_PORT "51820"
set SOCKS_PORT "43473"

echo "=== [0/5] Определение IP сервера ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
set RU_SOCKS_IP (ip -o -4 addr show dev $WG_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "Внешний интерфейс: $WG_IFACE"
echo "IP этого сервера (RU-SOCKS): $RU_SOCKS_IP"

echo "=== [1/5] Установка WireGuard ==="
apt install wireguard -y

echo "=== [2/5] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Публичный ключ RU-SOCKS сервера:                        ║"
echo "║  (добавить на LAT в wg0.conf первым [Peer])              ║"
echo "╚══════════════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""

echo "=== [3/5] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

# Адрес 10.0.0.2 — для RU-SOCKS (10.0.0.3 зарезервирован для RU-VPN)
printf '[Interface]\nAddress = 10.0.0.2/24\nPrivateKey = %s\nPostUp = ip rule add from %s table main\nPostDown = ip rule del from %s table main\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    $PRIVATE $RU_SOCKS_IP $RU_SOCKS_IP $LAT_PUBLIC_KEY $LAT_IP $WG_PORT \
    > /etc/wireguard/wg0.conf

echo "=== [4/5] Запуск WireGuard ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Проверка (должен быть латвийский IP):"
sleep 3
curl -s https://ifconfig.me
echo ""

echo "=== [5/5] Установка 3proxy (SOCKS5) ==="
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

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║         RU-SOCKS НАСТРОЙКА ЗАВЕРШЕНА      ║"
echo "╚═══════════════════════════════════════════╝"
wg show
systemctl status 3proxy --no-pager -l
echo ""
echo "Zero Omega настройки:"
echo "  Protocol: SOCKS5"
echo "  Server:   $RU_SOCKS_IP"
echo "  Port:     $SOCKS_PORT"
echo ""
