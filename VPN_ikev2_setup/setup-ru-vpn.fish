#!/usr/bin/env fish
# =============================================================================
# RU-VPN СЕРВЕР — IKEv2 VPN сервер с маршрутизацией через Латвию
# Схема: Device → IKEv2 (этот сервер) → WireGuard → LAT → Интернет
#
# Переменные которые нужно заменить перед запуском:
#   LAT_PUBLIC_KEY — публичный ключ LAT сервера
#   LAT_IP         — внешний IP LAT сервера
#
# ВАЖНО: запускать ПОСЛЕ того как LAT сервер настроен и добавил этот
#   сервер как peer (нужен публичный ключ этого сервера для LAT)
# =============================================================================

set LAT_PUBLIC_KEY "ВСТАВЬ_ПУБЛИЧНЫЙ_КЛЮЧ_С_LAT_СЕРВЕРА"
set LAT_IP "ВСТАВЬ_IP_LAT_СЕРВЕРА"
set WG_PORT "51820"
set VPN_CLIENT_NAME "vpnclient"

echo "=== [0/7] Определение IP сервера ==="
set WG_IFACE (ip -o -4 route show to default | awk '{print $5}')
set RU_VPN_IP (ip -o -4 addr show dev $WG_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "Внешний интерфейс: $WG_IFACE"
echo "IP этого сервера: $RU_VPN_IP"

echo "=== [1/7] Установка зависимостей ==="
apt update
apt install wireguard docker.io -y
systemctl enable docker
systemctl start docker

echo "=== [2/7] Генерация ключей WireGuard ==="
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Публичный ключ RU-VPN сервера:                  ║"
echo "║  (добавить на LAT в wg0.conf как [Peer])          ║"
echo "╚══════════════════════════════════════════════════╝"
cat /etc/wireguard/public.key
echo ""
echo "На LAT сервере выполни:"
echo "  wg set wg0 peer $(cat /etc/wireguard/public.key) allowed-ips 10.0.0.3/32"
echo "  wg-quick save wg0"
echo ""
read -P "Нажми Enter когда добавишь ключ на LAT сервер..."

echo "=== [3/7] Настройка WireGuard ==="
set PRIVATE (cat /etc/wireguard/private.key)

# PostUp: ip rule from RU_IP → main table (сохраняет SSH доступ)
# Без этого правила весь трафик (включая SSH) уйдёт через WireGuard
# и SSH соединение оборвётся
printf '[Interface]\nAddress = 10.0.0.3/24\nPrivateKey = %s\nPostUp = ip rule add from %s table main\nPostDown = ip rule del from %s table main\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
    $PRIVATE $RU_VPN_IP $RU_VPN_IP $LAT_PUBLIC_KEY $LAT_IP $WG_PORT \
    > /etc/wireguard/wg0.conf

echo "=== [4/7] Запуск WireGuard ==="
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "Проверка туннеля (внешний IP должен стать латвийским):"
sleep 3
curl -s https://ifconfig.me
echo ""

echo "=== [5/7] Настройка и запуск IKEv2 VPN контейнера ==="
mkdir -p ~/ikev2-vpn-data

# Проверяем: если ikev2.conf уже существует в volume — VPN_PUBLIC_IP не подействует!
# Источник: https://github.com/hwdsl2/docker-ipsec-vpn-server/blob/master/docs/advanced-usage.md#specify-vpn-servers-public-ip
# "Note that this variable has no effect for IKEv2 mode, if IKEv2 is already set up"
# При повторном запуске скрипта или наличии старого volume — удали ikev2.conf:
#   rm ~/ikev2-vpn-data/ikev2.conf   (только если нет нужных клиентов!)
if test -f ~/ikev2-vpn-data/ikev2.conf
    echo "⚠ ВНИМАНИЕ: ~/ikev2-vpn-data/ikev2.conf уже существует!"
    echo "  VPN_PUBLIC_IP не будет применён к IKEv2 автоматически."
    echo "  Если IP изменился — удали ikev2.conf и пересоздай контейнер."
    echo "  Продолжаем (left= будет исправлен вручную через sed ниже)..."
end

# КРИТИЧНО: явно задаём VPN_PUBLIC_IP = IP этого (RU) сервера
# Без этого контейнер автоопределит IP через интернет и получит латвийский IP
# (т.к. WireGuard уже маршрутизирует трафик через Латвию)
#
# VPN_IKEV2_ONLY=yes — отключает L2TP и XAuth (Cisco IPsec), оставляет только IKEv2
# Уменьшает поверхность атаки и убирает ненужные процессы
printf 'VPN_PUBLIC_IP=%s\nVPN_IPSEC_PSK=%s\nVPN_USER=vpnuser\nVPN_PASSWORD=%s\nVPN_IKEV2_ONLY=yes\n' \
    $RU_VPN_IP \
    (openssl rand -base64 16 | tr -d '=+/') \
    (openssl rand -base64 12 | tr -d '=+/') \
    > ~/vpn.env

echo "Создан vpn.env:"
cat ~/vpn.env
echo ""

# --network=host ОБЯЗАТЕЛЕН:
# С bridge сетью (-p 500:500/udp) docker-proxy перехватывает UDP в userspace,
# обходя iptables. IKEv2 ответы уходят через WireGuard в Латвию вместо
# прямого ответа клиенту. Клиент получает ответ от латвийского IP и отклоняет.
docker run \
    --name ipsec-vpn-server \
    --env-file ~/vpn.env \
    --restart=always \
    --network=host \
    -v ~/ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

echo "Ждём 40 секунд пока контейнер настроит IKEv2 и сертификаты..."
sleep 40
docker logs --tail 20 ipsec-vpn-server

echo "=== [6/7] Критические исправления после старта контейнера ==="

# ИСПРАВЛЕНИЕ 1: left=%defaultroute → реальный IP
# Libreswan при старте определяет интерфейс через маршрут по умолчанию.
# Т.к. default route = wg0 (WireGuard), он привязывается к wg0 (10.0.0.3)
# вместо eth0 (RU_VPN_IP). Клиент подключается к RU_VPN_IP:500 и получает
# ответ от 10.0.0.3 → NO_PROPOSAL_CHOSEN → соединение отклоняется.
# Изменение сохраняется в смонтированном volume (~/ikev2-vpn-data).
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=$RU_VPN_IP/" /etc/ipsec.d/ikev2.conf
echo "Проверяем исправление (должно быть left=$RU_VPN_IP):"
docker exec ipsec-vpn-server grep "^  left=" /etc/ipsec.d/ikev2.conf

docker exec ipsec-vpn-server ipsec restart
sleep 5

echo "Проверяем что IKEv2 привязан к eth0:"
docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:" | head -4

# ИСПРАВЛЕНИЕ 2: iptables для маршрутизации трафика VPN клиентов
# Контейнер при старте ПОЛНОСТЬЮ перезаписывает FORWARD chain и добавляет
# DROP all в конец. WireGuard правила (wg0) стираются. Восстанавливаем.

# Восстанавливаем WireGuard FORWARD правила (вставляем ПЕРЕД DROP)
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT

# VPN клиентам (192.168.43.0/24) нужен NAT через wg0 (не eth0!)
# Контейнер добавляет MASQUERADE только на eth0, но трафик идёт через wg0
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE

# MSS clamp КРИТИЧЕН для nested VPN (IKEv2 поверх WireGuard)
# MTU: eth0(1500) → WireGuard(1420) → IKEv2(~1360)
# Без этого большие TCP пакеты теряются и страницы не загружаются
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

echo "=== [7/7] Персистентность iptables правил ==="
# Создаём systemd сервис для восстановления правил после перезагрузки
# (контейнер при каждом старте сбрасывает FORWARD chain)

printf '#!/bin/bash\n# Восстанавливаем WireGuard FORWARD правила после старта контейнера\niptables -I FORWARD 1 -i wg0 -j ACCEPT\niptables -I FORWARD 2 -o wg0 -j ACCEPT\niptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE\niptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\n' \
    > /usr/local/bin/vpn-iptables-fix.sh
chmod +x /usr/local/bin/vpn-iptables-fix.sh

printf '[Unit]\nDescription=Fix iptables rules for IKEv2 VPN over WireGuard\nAfter=docker.service wg-quick@wg0.service\nWants=wg-quick@wg0.service docker.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStartPre=/bin/sleep 45\nExecStart=/usr/local/bin/vpn-iptables-fix.sh\n\n[Install]\nWantedBy=multi-user.target\n' \
    > /etc/systemd/system/vpn-iptables-fix.service

systemctl daemon-reload
systemctl enable vpn-iptables-fix.service

echo "=== Добавление VPN клиента ==="
echo "Зайди в контейнер и запусти интерактивный мастер:"
echo ""
echo "  docker exec -it ipsec-vpn-server ikev2.sh"
echo ""
echo "Выбери опцию 1 (Add a new client), имя: $VPN_CLIENT_NAME"
echo ""
echo "Скопируй .mobileconfig на устройство:"
echo "  scp root@$RU_VPN_IP:~/ikev2-vpn-data/$VPN_CLIENT_NAME.mobileconfig ./"
echo ""

echo "╔═══════════════════════════════════════════════════════╗"
echo "║                 НАСТРОЙКА ЗАВЕРШЕНА                   ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "WireGuard статус:"
wg show
echo ""
echo "IKEv2 статус:"
docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:|total"
echo ""
echo "Внешний IP сервера (должен быть латвийским):"
curl -s https://ifconfig.me
echo ""
echo "Настройки для подключения клиента:"
echo "  Адрес сервера: $RU_VPN_IP"
echo "  Тип:           IKEv2"
echo "  Аутентификация: по сертификату (.mobileconfig / .p12)"
echo ""
