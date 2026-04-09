#!/usr/bin/env fish
# =============================================================================
# ЛАТВИЙСКИЙ СЕРВЕР — Общая exit нода для SOCKS5 прокси И IKEv2 VPN
# Топология: 3 сервера (RU-SOCKS + RU-VPN → shared LAT)
#
# Схема:
#   [Browser] → RU-SOCKS (10.0.0.2) ──┐
#                                       ├── WG → LAT → Internet
#   [Device]  → RU-VPN  (10.0.0.3) ──┘
#
# Переменные которые нужно заменить перед запуском:
#   RU_SOCKS_PUBLIC_KEY — публичный ключ RU-SOCKS сервера
#   RU_VPN_PUBLIC_KEY   — публичный ключ RU-VPN сервера
# =============================================================================

set RU_SOCKS_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_RU_SOCKS_СЕРВЕРА"
set RU_VPN_PUBLIC_KEY   "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_RU_VPN_СЕРВЕРА"
set WG_PORT "51820"

echo "=== [0/3] Определение сетевого интерфейса ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
echo "Внешний интерфейс: $WG_IFACE"

echo "=== [1/3] Установка WireGuard ==="
apt install wireguard -y

echo "=== [2/3] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Публичный ключ LAT сервера:                             ║"
echo "║  (вставить в setup-ru-socks.fish → LAT_PUBLIC_KEY)       ║"
echo "║  (вставить в setup-ru-vpn.fish   → LAT_PUBLIC_KEY)       ║"
echo "╚══════════════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""

echo "=== [3/3] Настройка WireGuard с двумя peers ==="
set PRIVATE (cat /etc/wireguard/private.key)

printf '[Interface]\nAddress = 10.0.0.1/24\nPrivateKey = %s\nListenPort = %s\nPostUp = iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\nPostDown = iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n\n[Peer]\n# RU-SOCKS сервер (3proxy)\nPublicKey = %s\nAllowedIPs = 10.0.0.2/32\n\n[Peer]\n# RU-VPN сервер (IKEv2)\nPublicKey = %s\nAllowedIPs = 10.0.0.3/32\n' \
    $PRIVATE $WG_PORT $WG_IFACE $WG_IFACE \
    $RU_SOCKS_PUBLIC_KEY $RU_VPN_PUBLIC_KEY \
    > /etc/wireguard/wg0.conf

echo "=== Включение IP форвардинга и запуск ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                         ГОТОВО                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Следующие шаги:                                            ║"
echo "║  1. Запусти setup-ru-socks.fish на RU-SOCKS сервере         ║"
echo "║  2. Запусти setup-ru-vpn.fish на RU-VPN сервере             ║"
echo "║  3. Добавь их публичные ключи в этот конфиг (см. ниже)     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
wg show
echo ""
echo "Внешний IP (через него будут выходить оба сервера):"
curl -s https://ifconfig.me
echo ""
echo "Добавление нового peer вручную (если нужно):"
echo "  wg set wg0 peer <PUBLIC_KEY> allowed-ips 10.0.0.X/32"
echo "  wg-quick save wg0"
echo ""
