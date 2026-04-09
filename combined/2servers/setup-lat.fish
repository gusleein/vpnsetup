#!/usr/bin/env fish
# =============================================================================
# ЛАТВИЙСКИЙ СЕРВЕР — Exit нода для SOCKS5 + IKEv2 с одного RU сервера
# Топология: 2 сервера (один RU с SOCKS+VPN → LAT)
#
# Переменные которые нужно заменить:
#   RU_PUBLIC_KEY — публичный ключ RU сервера
# =============================================================================

set RU_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_RU_СЕРВЕРА"
set WG_PORT "51820"

echo "=== [0/3] Определение сетевого интерфейса ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
echo "Внешний интерфейс: $WG_IFACE"

echo "=== [1/3] Установка WireGuard ==="
apt install wireguard -y

echo "=== [2/3] Генерация ключей ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Публичный ключ LAT сервера:                             ║"
echo "║  (вставить в setup-ru-combined.fish → LAT_PUBLIC_KEY)    ║"
echo "╚══════════════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""

echo "=== [3/3] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

printf '[Interface]\nAddress = 10.0.0.1/24\nPrivateKey = %s\nListenPort = %s\nPostUp = iptables -t nat -A POSTROUTING -o %s -j MASQUERADE\nPostDown = iptables -t nat -D POSTROUTING -o %s -j MASQUERADE\n\n[Peer]\n# RU сервер (SOCKS5 + IKEv2 VPN)\nPublicKey = %s\nAllowedIPs = 10.0.0.2/32\n' \
    $PRIVATE $WG_PORT $WG_IFACE $WG_IFACE $RU_PUBLIC_KEY \
    > /etc/wireguard/wg0.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo ""
echo "=== Готово ==="
wg show
echo "Внешний IP:"
curl -s https://ifconfig.me
echo ""
