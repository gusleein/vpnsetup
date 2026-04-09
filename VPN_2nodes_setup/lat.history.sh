ll
# На LAT сервере:

# WG туннель с RU живой?
wg show wg0

# Пинг RU через WG
ping -c 3 10.0.0.2   # IP RU внутри WG (замени на свой)

# ip_forward включен?
cat /proc/sys/net/ipv4/ip_forward
# должно быть 1

# NAT настроен для выхода в интернет?
iptables -t nat -L POSTROUTING -n -v
# Должна быть строка: MASQUERADE -- * eth0

# Пакеты от RU видны на LAT?
tcpdump -i wg0 -n
tcpdump -i eth0 -n icmp

# Тест: с LAT сервера ходит интернет?
curl -s https://ifconfig.me
wg show  # должно быть два peer-а: 10.0.0.2 и 10.0.0.3
# Добавляем RU-VPN как второй peer (не пересоздаём, а дописываем!)
wg set wg0 peer rMY3uTmTZvnSOfH9Za/6zrvNB+I+HAW+rfmJf+eleGY= allowed-ips 10.0.0.3/32
# И в конфиг файл, чтобы пережило reboot:
echo "
[Peer]
PublicKey = rMY3uTmTZvnSOfH9Za/6zrvNB+I+HAW+rfmJf+eleGY=
AllowedIPs = 10.0.0.3/32" >> /etc/wireguard/wg0.conf
# Добавляем RU-VPN как второй peer (не пересоздаём, а дописываем!)
wg set wg0 peer rMY3uTmTZvnSOfH9Za/6zrvNB+I+HAW+rfmJf+eleGY= allowed-ips 10.0.0.3/32\
\# И в конфиг файл, чтобы пережило reboot:
echo "
[Peer]
PublicKey = rMY3uTmTZvnSOfH9Za/6zrvNB+I+HAW+rfmJf+eleGY=
AllowedIPs = 10.0.0.3/32" >> /etc/wireguard/wg0.conf
history | cat
wg show; echo "---"; ip addr show wg0; echo "---"; ip route; echo "---"; ping -c 3 10.0.0.1; echo "---"; curl -s https://ifconfig.me
systemctl stop wg-quick@wg0
set PRIVATE (cat /etc/wireguard/private.key)
echo "[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE
ListenPort = 51820
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = GpAJO3ni/3MZE2SPo7MUFkwBYy2iTY8VeM7FWZhWrCY=
AllowedIPs = 10.0.0.2/32" > /etc/wireguard/wg0.conf
systemctl start wg-quick@wg0
ip addr show wg0
ip addr show wg0
wg show
ping -c 3 10.0.0.1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
systemctl status wg-quick@wg0
cat /etc/wireguard/wg0.conf

set PRIVATE (cat /etc/wireguard/private.key)

echo "[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE
ListenPort = 51820
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = GpAJO3ni/3MZE2SPo7MUFkwBYy2iTY8VeM7FWZhWrCY=
AllowedIPs = 10.0.0.2/32" > /etc/wireguard/wg0.conf
set PRIVATE (cat /etc/wireguard/private.key)

echo "[Interface]
Address = 10.0.0.1/24
PrivateKey = $PRIVATE
ListenPort = 51820
PostUp = iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = РОССИЙСКИЙ_PUBKEY
AllowedIPs = 10.0.0.2/32" > /etc/wireguard/wg0.conf
apt install wireguard -y
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
cat /etc/wireguard/private.key
cat /etc/wireguard/public.key
ip -o -4 route show to default | awk '{print $5}'
cat /etc/os-release
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAgNIEo8mndRCf1l/KO5pQrYyIsiX1vLty91hHkUeKOk user@MacBook-Pro-arturoos.local" >> .ssh/authorized_keys
iperf3 -c 10.16.0.2
iperf3 -c 45.12.74.70
apt install iperf3
top
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p
apt update && apt install -y wireguard
vi /etc/passwd
apt install fish
vi /etc/systemd/system/ssh-proxy.service
systemctl stop ssh-proxy.service
systemctl disable ssh-proxy.service
systemctl status ssh-proxy.service
systemctl start ssh-proxy.service
systemctl enable ssh-proxy.service
systemctl daemon-reload
vi .ssh/authorized_keys
