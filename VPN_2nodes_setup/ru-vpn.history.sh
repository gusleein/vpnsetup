# Восстанавливаем правила WireGuard в FORWARD (до DROP)
iptables -I FORWARD 1 -i wg0 -j ACCEPT
iptables -I FORWARD 2 -o wg0 -j ACCEPT

# MASQUERADE для VPN клиентов через wg0 (в Латвию)
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE

# MSS clamp — критично для nested VPN (IKEv2 внутри WireGuard)
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# NAT для VPN клиентов (их трафик идёт через wg0 → Латвия)
iptables -t nat -A POSTROUTING -s 192.168.43.0/24 -o wg0 -j MASQUERADE

# Форвардинг для VPN клиентов
iptables -A FORWARD -s 192.168.43.0/24 -j ACCEPT
iptables -A FORWARD -d 192.168.43.0/24 -j ACCEPT

# MSS clamp — важно! без этого большие пакеты теряются в nested VPN
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
# Что есть в iptables для VPN клиентов (192.168.43.x)
iptables -t nat -L POSTROUTING -n -v | grep -E "192.168|MASQ"
iptables -L FORWARD -n -v | head -20

# Есть ли маршрут для VPN клиентов
ip route show
docker exec ipsec-vpn-server ipsec status | grep -E "ESTABLISHED|total|half"
curl -s https://ifconfig.me
reboot
docker exec ipsec-vpn-server ipsec restart
sleep 5

docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:" | head -5
docker exec ipsec-vpn-server sed -i "s/left=%defaultroute/left=212.67.9.130/" /etc/ipsec.d/ikev2.conf

# Проверяем
docker exec ipsec-vpn-server grep "left" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server ipsec restart
sleep 5

# Проверяем — должно быть interface: eth0, local: 212.67.9.130
docker exec ipsec-vpn-server ipsec status | grep -E "interface:|local:|ikev2-cp" | head -10
docker exec ipsec-vpn-server sed -i "s/^left=.*/left=212.67.9.130/" /etc/ipsec.d/ikev2.conf

# Проверяем результат
docker exec ipsec-vpn-server grep -E "left|interface" /etc/ipsec.d/ikev2.conf
docker exec ipsec-vpn-server cat /etc/ipsec.d/ikev2.conf
docker stop ipsec-vpn-server && docker rm ipsec-vpn-server
                            
                            docker run \
                                    --name ipsec-vpn-server \
                                    --env-file ~/vpn.env \
                                    --restart=always \
                                    --network=host \
                                    -v ~/ikev2-vpn-data:/etc/ipsec.d \
                                    -v /lib/modules:/lib/modules:ro \
                                    -d --privileged \
                                    hwdsl2/ipsec-vpn-server

                            sleep 15
                            docker logs --tail 30 ipsec-vpn-server
vi vpn.env
../
./ikev2-vpn-data/
docker exec -it ipsec-vpn-server bash
docker logs ipsec-vpn-server
cat vpn.env
ll
vi ikev2.conf
# На RU сервере (хост):

# Статус WG туннеля
wg show wg0
# Смотри: "latest handshake" — если давно или нет, туннель мёртв

# Пинг LAT через WG
ping -c 3 10.0.0.1   # IP LAT внутри WG сети (замени на свой)

# Трафик идёт через wg0?
tcpdump -i wg0 -n icmp

# Маршруты — куда уходит трафик с VPN-клиентов
ip route show table main
ip route show table all | grep wg0

# Проверь что трафик с VPN-IP форвардится в wg0
iptables -t nat -L POSTROUTING -n -v
# Должна быть строка MASQUERADE для интерфейса wg0
# 1. Docker контейнер живой?
docker ps | grep ipsec
docker logs ipsec-vpn-server --tail 50

# 2. Порты слушаются?
ss -ulnp | grep -E "500|4500"
# или
netstat -ulnp | grep -E "500|4500"

# 3. Пакеты от device доходят до хоста?
tcpdump -i eth0 udp port 500 or udp port 4500
# (замени eth0 на твой интерфейс — ip a)

# 4. Firewall не режет?
iptables -L INPUT -n -v | head -30
iptables -L FORWARD -n -v | head -30

# 5. ip_forward включен?
cat /proc/sys/net/ipv4/ip_forward
# должно быть 1

# 6. WireGuard интерфейс есть?
ip a show wg0
wg show
# На сервере — смотрим что происходит при подключении
docker exec ipsec-vpn-server ipsec status 2>&1 | grep -E 'ESTABLISHED|total|half'
curl -s https://ifconfig.me
ipsec status
# Терминал 3 — ip rules не сломались?
ip rule list
# Терминал 2 — логи контейнера в реальном времени
docker logs -f ipsec-vpn-server 2>&1 | grep -v "xl2tpd"
# Терминал 1 — смотрим статус в реальном времени
watch -n 1 "docker exec ipsec-vpn-server ipsec status 2>&1 | grep -E 'ESTABLISHED|half-open|total|INIT|AUTH|ERROR'"
ip rule del from 172.17.0.0/16 table main priority 100

ip rule list

cat /etc/wireguard/wg0.conf
iptables -t mangle -F PREROUTING
docker stop ipsec-vpn-server && docker rm ipsec-vpn-server

docker run \
    --name ipsec-vpn-server \
    --env-file ~/vpn.env \
    --restart=always \
    --network=host \
    -v ~/ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

sleep 15
docker logs --tail 30 ipsec-vpn-server
systemctl restart wg-quick@wg0
sleep 3
wg show
printf '[Interface]\nAddress = 10.0.0.3/24\nPrivateKey = wMCFw5V0QvXgg0umOe20TM1mya7AlKNCMlpbKBhwa1g=\nPostUp = ip rule add from 212.67.9.130 table main\nPostDown = ip rule del from 212.67.9.130 table main\n\n[Peer]\nPublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=\nEndpoint = 46.173.20.212:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' > /etc/wireguard/wg0.conf

cat /etc/wireguard/wg0.conf
vi /etc/wireguard/wg0.conf
cat /etc/wireguard/wg0.conf
# Остановить и удалить старый контейнер (данные сохранятся в ikev2-vpn-data)
docker stop ipsec-vpn-server
docker rm ipsec-vpn-server

# Запустить с host-сетью (без -p портов, без bridge)
docker run \
    --name ipsec-vpn-server \
    --env-file ~/vpn.env \
    --restart=always \
    --network=host \
    -v ~/ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

# Подождать ~10 секунд пока запустится
sleep 10
docker logs --tail 20 ipsec-vpn-server
iptables -t mangle -F PREROUTING
ip rule add from 172.17.0.0/16 table main priority 100
tcpdump -i wg0 -n "dst 188.170.79.86 or dst 109.174.126.169" -c 10 &tcpdump -i wg0 -n "dst 188.170.79.86 or dst 109.174.126.169" -c 10 &
tcpdump -i eth0 -n "dst 188.170.79.86 or dst 109.174.126.169" -c 10 &
ll ikev2-vpn-data/
tcpdump -i eth0 -n "udp and src port 500 and src host 212.67.9.130" -c 10
watch -n 1 "iptables -t mangle -L PREROUTING -n -v"
# Проверяем текущий daemon.json
cat /etc/docker/daemon.json 2>/dev/null || echo "нет файла"
# Отключаем userland-proxy
echo '{"userland-proxy": false}' > /etc/docker/daemon.json
# Перезапускаем Docker (контейнер поднимется сам, restart=always)
systemctl restart docker
# Ждём старта контейнера
sleep 8
docker ps | grep ipsec
# Применяем mangle-правило заново (wg0 PostUp не перезапускался)
iptables -t mangle -A PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0xca6c
# Проверяем DNAT от Docker (без proxy — только iptables)
iptables -t nat -L DOCKER -n -v | grep -E "500|4500"
iptables -t mangle -L PREROUTING -n -v
echo "=== DOCKER DAEMON CONFIG ===" ; cat /etc/docker/daemon.json 2>/dev/null || echo "нет файла"
echo "=== DOCKER VERSION ===" ; docker version
echo "=== DOCKER INFO ===" ; docker info
echo "=== CONTAINER INSPECT ===" ; docker inspect ipsec-vpn-server
echo "=== CONTAINER ENV ===" ; docker exec ipsec-vpn-server env 2>/dev/null | grep -v PASSWORD | grep -v SECRET | grep -v PSK
echo "=== CONTAINER PROCESSES ===" ; docker exec ipsec-vpn-server ps aux 2>/dev/null
echo "=== CONTAINER IPTABLES ===" ; docker exec ipsec-vpn-server iptables -L -n -v 2>/dev/null
echo "=== CONTAINER IPTABLES NAT ===" ; docker exec ipsec-vpn-server iptables -t nat -L -n -v 2>/dev/null
echo "=== CONTAINER IPTABLES MANGLE ===" ; docker exec ipsec-vpn-server iptables -t mangle -L -n -v 2>/dev/null
echo "=== CONTAINER IP ROUTE ===" ; docker exec ipsec-vpn-server ip route 2>/dev/null
echo "=== CONTAINER IP RULE ===" ; docker exec ipsec-vpn-server ip rule list 2>/dev/null
echo "=== CONTAINER NETNS ===" ; docker exec ipsec-vpn-server ls /proc/net/ 2>/dev/null
echo "=== HOST IPTABLES FULL ===" ; iptables-save
echo "=== HOST IP RULES ===" ; ip rule list
echo "=== HOST ROUTES ALL ===" ; ip route show table all
echo "=== HOST SS ===" ; ss -ulnp
echo "=== DOCKER PROXY PROCESSES ===" ; ps aux | grep -E "docker-proxy|dockerd"
echo "=== DOCKER NETWORKS ===" ; docker network inspect bridge
echo "=== BRIDGE CONFIG ===" ; brctl show 2>/dev/null || bridge link show
echo "=== BRIDGE NF SYSCTL ===" ; sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-arptables net.bridge.bridge-nf-call-ip6tables 2>/dev/null
echo "=== IP FORWARD ===" ; sysctl net.ipv4.ip_forward net.ipv4.conf.all.forwarding net.ipv4.conf.docker0.forwarding 2>/dev/null
echo "=== CONNTRACK MAX ===" ; sysctl net.netfilter.nf_conntrack_max 2>/dev/null
echo "=== SYSTEMD DOCKER ===" ; systemctl cat docker.service | head -40
echo "=== WG0 CONF ===" ; cat /etc/wireguard/wg0.conf
echo "=== WG SHOW ===" ; wg show
# Убираем нерабочий подход
ip rule del fwmark 0x100 table main priority 99
iptables -t mangle -D PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0x100
# Помечаем IKEv2 трафик mark'ом самого WireGuard
iptables -t mangle -A PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0xca6c
# Проверяем что теперь маршрут через eth0
ip route get 188.170.79.86 from 172.17.0.2 iif docker0 mark 0xca6c
# Обновляем wg0.conf для персистентности
set PRIVATE (cat /etc/wireguard/private.key)
echo "[Interface]
Address = 10.0.0.3/24
PrivateKey = $PRIVATE
PostUp = ip rule add from 212.67.9.130 table main; iptables -t mangle -A PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0xca6c
PostDown = ip rule del from 212.67.9.130 table main; iptables -t mangle -D PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0xca6c
[Peer]
PublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=
Endpoint = 46.173.20.212:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > /etc/wireguard/wg0.conf
# Проверяем ip rules
ip rule list
iptables -t mangle -L PREROUTING -n -v
timeout 15 tcpdump -i docker0 -n "udp and src 172.17.0.2" -c 20
iptables -t mangle -L PREROUTING -n -v
timeout 15 tcpdump -i wg0 -n -c 30
iptables -L DOCKER-FORWARD -n -v
iptables -L DOCKER-USER -n -v
tcpdump -i any -n "udp port 500 or udp port 4500" -l
watch -n 1 "docker exec ipsec-vpn-server ipsec status 2>&1 | grep -E 'ESTABLISHED|half-open|total|INIT|AUTH'"
echo "=== FORWARD CHAIN ===" ; iptables -L FORWARD -n -v --line-numbers
echo "=== MANGLE ALL CHAINS ===" ; iptables -t mangle -L -n -v
echo "=== CONNTRACK TABLE ===" ; conntrack -L 2>/dev/null | grep -E "500|4500" | head -20 || echo "conntrack не установлен"
echo "=== DOCKER NETWORK ===" ; docker network ls ; docker inspect ipsec-vpn-server | grep -E "IPAddress|Gateway|NetworkMode"
echo "=== CONTAINER IPTABLES NAT ===" ; docker exec ipsec-vpn-server iptables -t nat -L -n -v 2>&1 | head -30
echo "=== CONTAINER ROUTES ===" ; docker exec ipsec-vpn-server ip route
echo "=== CONTAINER IP RULES ===" ; docker exec ipsec-vpn-server ip rule list 2>/dev/null
echo "=== HOST ROUTE TABLE MAIN ===" ; ip route show table main
echo "=== HOST ROUTE TABLE WG ===" ; ip route show table 51820
# Убираем грубое правило
ip rule del from 172.17.0.0/16 table main priority 100
# Маркируем IKEv2-трафик от контейнера (sport 500 и 4500)
iptables -t mangle -A PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0x100
# Маршрутизируем помеченный трафик через main (eth0)
ip rule add fwmark 0x100 table main priority 99
# Проверяем
ip rule list
iptables -t mangle -L PREROUTING -n -v
# Сохраняем в wg0.conf
set PRIVATE (cat /etc/wireguard/private.key)
echo "[Interface]
Address = 10.0.0.3/24
PrivateKey = $PRIVATE
PostUp = ip rule add from 212.67.9.130 table main; ip rule add fwmark 0x100 table main priority 99; iptables -t mangle -A PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0x100
PostDown = ip rule del from 212.67.9.130 table main; ip rule del fwmark 0x100 table main priority 99; iptables -t mangle -D PREROUTING -i docker0 -p udp -m multiport --sports 500,4500 -j MARK --set-mark 0x100
[Peer]
PublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=
Endpoint = 46.173.20.212:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > /etc/wireguard/wg0.conf
watch -n 1 "docker exec ipsec-vpn-server ipsec status | grep -E 'ESTABLISHED|half-open|total'"
# Применяем сразу (без перезапуска)
ip rule add from 172.17.0.0/16 table main priority 100

# Проверяем правила
ip rule list

# Обновляем wg0.conf чтобы пережило reboot
set PRIVATE (cat /etc/wireguard/private.key)
echo "[Interface]
Address = 10.0.0.3/24
PrivateKey = $PRIVATE
PostUp = ip rule add from 212.67.9.130 table main; ip rule add from 172.17.0.0/16 table main priority 100
PostDown = ip rule del from 212.67.9.130 table main; ip rule del from 172.17.0.0/16 table main priority 100

[Peer]
PublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=
Endpoint = 46.173.20.212:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > /etc/wireguard/wg0.conf

# Проверяем что всё ок
ip rule list
curl -s https://ifconfig.me  # должен быть латвийский IP
echo "=== DOCKER ===" ; docker ps -a | grep ipsec
echo "=== CONTAINER LOGS (последние 30) ===" ; docker logs --tail 30 ipsec-vpn-server 2>&1
echo "=== IPSEC STATUS ===" ; docker exec ipsec-vpn-server ipsec status 2>&1
echo "=== ПОРТЫ (500, 4500) ===" ; ss -ulnp | grep -E "500|4500"
echo "=== UFW ===" ; ufw status 2>/dev/null || iptables -L INPUT -n --line-numbers | head -30
echo "=== ВНЕШНИЙ IP ===" ; curl -s --max-time 5 https://ifconfig.me
echo "=== WIREGUARD ===" ; wg show 2>/dev/null || echo "wg не запущен"
echo "=== МАРШРУТЫ ===" ; ip route
echo "=== IP RULES ===" ; ip rule list
echo "=== IPTABLES NAT ===" ; iptables -t nat -L -n -v 2>&1 | head -40
echo "=== SYSCTL FORWARD ===" ; sysctl net.ipv4.ip_forward net.ipv4.conf.all.forwarding 2>&1
wg show; curl -s https://ifconfig.me
set PRIVATE (cat /etc/wireguard/private.key)
set RU_VPN_IP "212.67.9.130"  # внешний IP wxreyzwxeb

echo "[Interface]
Address = 10.0.0.3/24
PrivateKey = $PRIVATE
PostUp = ip rule add from $RU_VPN_IP table main
PostDown = ip rule del from $RU_VPN_IP table main

[Peer]
PublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=
Endpoint = 46.173.20.212:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > /etc/wireguard/wg0.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
set PRIVATE (cat /etc/wireguard/private.key)
wwset RU_VPN_IP "ВОТ_РЕАЛЬНЫЙ_IP_СЕРВЕРА"  # внешний IP wxreyzwxeb

echo "[Interface]
Address = 10.0.0.3/24
PrivateKey = $PRIVATE
PostUp = ip rule add from $RU_VPN_IP table main
PostDown = ip rule del from $RU_VPN_IP table main

[Peer]
PublicKey = OpxFmPI6GGTC5ydBNqcpwLPgyb+lkGrvcmAMqheJRlI=
Endpoint = 46.173.20.212:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > /etc/wireguard/wg0.conf

echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
# Генерируем новую пару ключей (отдельная от RU-SOCKS)
apt install wireguard -y
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
cat /etc/wireguard/public.key   # этот ключ вставить на LAT
ip addr show  # узнать IP сервера для PostUp правила
docker exec -it ipsec-vpn-server ipsec
docker exec -it ipsec-vpn-server
docker exec -it ipsec-vpn-server ipsec status
history | cat
history | cate
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgNIEo8mndRCf1l/KO5pQrYyIsiX1vLty91hHkUeKOk user@MacBook-Pro-arturoos.local" >> .ssh/authorized_keys
la ikev2-vpn-data/
la
docker ps
iperf3 -c 10.16.0.2
iperf3 -c 45.12.74.70
apt install iperf3 -y
apt install iperf3 -c 10.16.0.2
history
docker run \
    --name ipsec-vpn-server \
    --env-file ./vpn.env \
    --restart=always \
    -v ./ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

docker stop ipsec-vpn-server; docker rm ipsec-vpn-server
docker run \
    --name ipsec-vpn-server \
    --env-file ./vpn.env \
    --restart=always \
    -v ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
    hwdsl2/ipsec-vpn-server

docker run \
    --name ipsec-vpn-server \
    --restart=always \
    -v ./ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
-v /root/vpn.env:/opt/src/vpn.env \
    hwdsl2/ipsec-vpn-server
rm ikev2-vpn-data/*
touch vpn.env
rm -rf vpn.env/
docker run \
    --name ipsec-vpn-server \
    --restart=always \
    -v ./ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
-v ./vpn.env:/opt/src/vpn.env \
    hwdsl2/ipsec-vpn-server
docker run \
  --name ipsec-vpn-server \
  --restart=always \
  -d \
  --privileged \
  -p 500:500/udp \
  -p 4500:4500/udp \
  -v /opt/vpn:/etc/ipsec.d \
  -v /opt/vpn/vpn.env:/opt/src/vpn.env \
-v /lib/modules:/lib/modules:ro \
  hwdsl2/ipsec-vpn-server

docker run \
  --name ipsec-vpn-server \
  --restart=always \
  -d \
  --privileged \
  -p 500:500/udp \
  -p 4500:4500/udp \
  -v /opt/vpn:/etc/ipsec.d \
  -v /opt/vpn/vpn.env:/opt/src/vpn.env 
  hwdsl2/ipsec-vpn-server

docker run \
  --name ipsec-vpn-server \
  --restart=always \
  -d \
  --privileged \
  -p 500:500/udp \
  -p 4500:4500/udp \
  -v /opt/vpn:/etc/ipsec.d \
  -v /opt/vpn/vpn.env:/opt/src/vpn.env \
  hwdsl2/ipsec-vpn-server

la /opt/vpn/
docker rm ipsec-vpn-server
docker stop ipsec-vpn-server
sudo mkdir -p /opt/vpn
sudo touch /opt/vpn/vpn.env

docker run \
    --name ipsec-vpn-server \
    --restart=always \
    -v ./ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
-e vpn.env \
    hwdsl2/ipsec-vpn-server
ikev2-vpn-data/
cat ikev2-vpn-data/
ls
docker run \
    --name ipsec-vpn-server \
    --restart=always \
    -v ./ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
    hwdsl2/ipsec-vpn-server
docker run \
    --name ipsec-vpn-server \
    --restart=always \
    -v ikev2-vpn-data:/etc/ipsec.d \
    -v /lib/modules:/lib/modules:ro \
    -p 500:500/udp \
    -p 4500:4500/udp \
    -d --privileged \
    hwdsl2/ipsec-vpn-server
vi /etc/passwd
apt install fish
