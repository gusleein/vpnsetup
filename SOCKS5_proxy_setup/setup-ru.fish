#!/usr/bin/env fish
# =============================================================================
# РОССИЙСКИЙ СЕРВЕР — Установка SOCKS5 прокси (3proxy) + WireGuard туннель
# Схема: Клиенты → SOCKS5 :43473 → WireGuard → Латвийский сервер → Интернет
#
# Переменные которые нужно заменить перед запуском:
#   LAT_PUBLIC_KEY  — публичный ключ латвийского сервера
#   LAT_IP          — IP латвийского сервера
#   RU_OWN_IP       — внешний IP этого сервера (для сохранения SSH)
# =============================================================================

set LAT_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_С_LAT_СЕРВЕРА"
set LAT_IP "ВСТАВЬ_IP_ЛАТВИЙСКОГО_СЕРВЕРА"
set WG_PORT "51820"
set SOCKS_PORT "43473"

echo "=== [0/5] Определение IP и интерфейса ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
set RU_OWN_IP (ip -o -4 addr show dev $WG_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "Внешний интерфейс: $WG_IFACE"
echo "IP этого сервера: $RU_OWN_IP"

echo "=== [1/5] Установка WireGuard ==="
apt install wireguard -y

echo "=== [2/5] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Публичный ключ этого (RU) сервера:              ║"
echo "║  (вставить в setup-lat.fish → RU_PUBLIC_KEY)     ║"
echo "╚══════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""

echo "=== [3/5] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

printf '[Interface]\nAddress = 10.0.0.2/24\nPrivateKey = %s\nPostUp = ip rule add from %s table main\nPostDown = ip rule del from %s table main\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    $PRIVATE $RU_OWN_IP $RU_OWN_IP $LAT_PUBLIC_KEY $LAT_IP $WG_PORT \
    > /etc/wireguard/wg0.conf

echo "=== [4/5] Включение форвардинга и запуск WireGuard ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Проверка туннеля (внешний IP должен стать латвийским):"
sleep 3
curl -s https://ifconfig.me
echo ""

echo "=== [5/5] Установка 3proxy ==="
# Пробуем скачать готовый deb-пакет
set ARCH (dpkg --print-architecture)
if test "$ARCH" = "amd64"
    echo "Скачиваем готовый deb-пакет..."
    cd /tmp
    curl -LJO https://github.com/3proxy/3proxy/releases/download/0.9.5/3proxy-0.9.5.x86_64.deb 2>/dev/null
    if test -f 3proxy-0.9.5.x86_64.deb
        apt install -y ./3proxy-0.9.5.x86_64.deb
        set PROXY_BIN /usr/local/bin/3proxy
    else
        echo "deb не скачался, собираем из исходников..."
        apt install git make gcc -y
        git clone https://github.com/3proxy/3proxy.git /tmp/3proxy-src
        cd /tmp/3proxy-src
        make -f Makefile.Linux
        cp src/3proxy /usr/local/bin/
        chmod 755 /usr/local/bin/3proxy
        set PROXY_BIN /usr/local/bin/3proxy
    end
else
    echo "Сборка из исходников (не amd64)..."
    apt install git make gcc -y
    git clone https://github.com/3proxy/3proxy.git /tmp/3proxy-src
    cd /tmp/3proxy-src
    make -f Makefile.Linux
    cp src/3proxy /usr/local/bin/
    chmod 755 /usr/local/bin/3proxy
    set PROXY_BIN /usr/local/bin/3proxy
end

mkdir -p /etc/3proxy /var/log/3proxy

printf '#!/bin/3proxy\ninclude /etc/3proxy/conf.cfg\n' > /etc/3proxy/3proxy.cfg

printf 'nscache 65536\nnserver 8.8.8.8\nnserver 8.8.4.4\n\nlog /var/log/3proxy/3proxy-%%y%%m%%d.log D\nrotate 60\n\nauth none\nallow *\nsocks -p%s\n' $SOCKS_PORT > /etc/3proxy/conf.cfg

printf '[Unit]\nDescription=3proxy Proxy Server\nAfter=network.target\n\n[Service]\nExecStart=%s /etc/3proxy/3proxy.cfg\nRestart=always\nRestartSec=5\nLimitNOFILE=65535\n\n[Install]\nWantedBy=multi-user.target\n' $PROXY_BIN > /etc/systemd/system/3proxy.service

systemctl daemon-reload
systemctl enable 3proxy
systemctl start 3proxy

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║             НАСТРОЙКА ЗАВЕРШЕНА            ║"
echo "╚═══════════════════════════════════════════╝"
echo ""
echo "WireGuard:"
wg show
echo ""
echo "3proxy:"
systemctl status 3proxy --no-pager -l
echo ""
echo "Внешний IP (должен быть латвийским):"
curl -s https://ifconfig.me
echo ""
echo "Настройки для браузера (Zero Omega):"
echo "  Protocol: SOCKS5"
echo "  Server:   $RU_OWN_IP"
echo "  Port:     $SOCKS_PORT"
echo ""
