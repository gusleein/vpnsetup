#!/usr/bin/env fish
# =============================================================================
# RU-VPN СЕРВЕР — IKEv2 VPN с выходом через общий LAT сервер
# Топология: 3 сервера (RU-SOCKS + RU-VPN → shared LAT)
#
# Переменные которые нужно заменить перед запуском:
#   LAT_PUBLIC_KEY — публичный ключ LAT сервера
#   LAT_IP         — внешний IP LAT сервера
# =============================================================================

set LAT_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_LAT_СЕРВЕРА"
set LAT_IP "ВСТАВЬ_IP_LAT_СЕРВЕРА"
set WG_PORT "51820"
set VPN_CLIENT_NAME "vpnclient"

echo "=== [0/7] Определение IP сервера ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
set RU_VPN_IP (ip -o -4 addr show dev $WG_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "IP этого сервера (RU-VPN): $RU_VPN_IP"

echo "=== [1/7] Установка зависимостей ==="
apt update
apt install wireguard docker.io -y
systemctl enable docker && systemctl start docker

echo "=== [2/7] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Публичный ключ RU-VPN сервера:                          ║"
echo "║  (добавить на LAT в wg0.conf вторым [Peer])              ║"
echo "╚══════════════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""
echo "На LAT сервере выполни:"
echo "  wg set wg0 peer $(cat /etc/wireguard/public.key) allowed-ips 10.0.0.3/32"
echo "  wg-quick save wg0"
echo ""
read -P "Нажми Enter когда добавишь ключ на LAT сервер..."

echo "=== [3/7] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

# Адрес 10.0.0.3 — для RU-VPN (10.0.0.2 — RU-SOCKS)
printf '[Interface]\nAddress = 10.0.0.3/24\nPrivateKey = %s\nPostUp = ip rule add from %s table main\nPostDown = ip rule del from %s table main\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    $PRIVATE $RU_VPN_IP $RU_VPN_IP $LAT_PUBLIC_KEY $LAT_IP $WG_PORT \
    > /etc/wireguard/wg0.conf

echo "=== [4/7] Запуск WireGuard ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
sleep 3
echo "Внешний IP (должен быть латвийским):"
curl -s https://ifconfig.me
echo ""

echo "=== [5/7] Запуск IKEv2 VPN контейнера ==="
mkdir -p ~/ikev2-vpn-data

# ВАЖНО: VPN_PUBLIC_IP не применяется к IKEv2, если ikev2.conf уже существует в volume
# Подробнее: https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip
if test -f ~/ikev2-vpn-data/ikev2.conf
    echo "⚠ ikev2.conf уже существует — VPN_PUBLIC_IP не обновит IKEv2 сертификат."
    echo "  left= будет исправлен через sed ниже."
end

# VPN_IKEV2_ONLY=yes — только IKEv2, без L2TP и XAuth
printf 'VPN_PUBLIC_IP=%s\nVPN_IPSEC_PSK=%s\nVPN_USER=vpnuser\nVPN_PASSWORD=%s\nVPN_IKEV2_ONLY=yes\n' \
    $RU_VPN_IP \
    (openssl rand -base64 16 | tr -d '=+/') \
    (openssl rand -base64 12 | tr -d '=+/') \
    > ~/vpn.env

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

echo "=== [6/7] Исправления после старта контейнера ==="
# Фикс: left=%defaultroute → реальный IP
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=$RU_VPN_IP/" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
sleep 5
docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:" | head -3

# Восстановление iptables правил
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "=== [7/7] Персистентность iptables ==="
printf '#!/bin/bash\niptables -I FORWARD 1 -i wg0 -j ACCEPT\niptables -I FORWARD 2 -o wg0 -j ACCEPT\niptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE\niptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n' \
    > /usr/local/bin/vpn-iptables-fix.sh
chmod +x /usr/local/bin/vpn-iptables-fix.sh

printf '[Unit]\nDescription=Fix iptables for IKEv2 VPN over WireGuard\nAfter=docker.service wg-quick@wg0.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStartPre=/bin/sleep 45\nExecStart=/usr/local/bin/vpn-iptables-fix.sh\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/vpn-iptables-fix.service

systemctl daemon-reload
systemctl enable vpn-iptables-fix.service

echo ""
echo "=== Добавление VPN клиента ==="
echo "  docker exec -it ipsec-vpn-server ikev2.sh"
echo "  # Выбрать: 1) Add a new client"
echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║         RU-VPN НАСТРОЙКА ЗАВЕРШЕНА        ║"
echo "╚═══════════════════════════════════════════╝"
wg show
docker exec ipsec-vpn-server ipsec status | grep -E "total|interface:|local:"
echo "Внешний IP:" ; curl -s https://ifconfig.me
echo ""
