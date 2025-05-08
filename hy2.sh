#!/bin/bash

# Install required packages
apk add wget curl git openssh openssl openrc

# Function to generate a random password
generate_random_password() {
  dd if=/dev/random bs=18 count=1 status=none | base64
}

# Prompt user for custom inputs with defaults
read -p "请输入端口（默认 40443）: " PORT
PORT=${PORT:-40443}

read -p "请输入密码（回车则使用随机密码）: " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD="$(generate_random_password)"
fi

read -p "请输入伪装域名（默认 bing.com）: " SNI
SNI=${SNI:-bing.com}

# Get server IP address
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
  echo "无法获取服务器 IP 地址，请检查网络连接。"
  exit 1
fi

# Function to generate Hysteria config.yaml
echo_hysteria_config_yaml() {
  cat << EOF
listen: :$PORT

# 有域名时使用 CA 证书（默认注释掉）
#acme:
#  domains:
#    - test.heybro.bid # 你的域名，需要先解析到服务器 IP
#  email: xxx@gmail.com

# 使用自签名证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true
EOF
}

# Function to generate OpenRC auto-start script
echo_hysteria_autoStart() {
  cat << EOF
#!/sbin/openrc-run

name="hysteria"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"

pidfile="/var/run/\${name}.pid"

command_background="yes"

depend() {
  need networking
}
EOF
}

# Download Hysteria binary and make it executable
wget -O /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64 --no-check-certificate
chmod +x /usr/local/bin/hysteria

# Create Hysteria config directory
mkdir -p /etc/hysteria/

# Generate self-signed TLS certificate
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=$SNI" -days 36500

# Write configuration file
echo_hysteria_config_yaml > "/etc/hysteria/config.yaml"

# Write and configure auto-start script
echo_hysteria_autoStart > "/etc/init.d/hysteria"
chmod +x /etc/init.d/hysteria
rc-update add hysteria

# Start Hysteria service
service hysteria start

# Generate v2ray subscription link
SUBSCRIPTION_LINK="hy2://${PASSWORD}@${SERVER_IP}:${PORT}?insecure=0&sni=${SNI}#hysteria2"

# Output installation summary
echo "------------------------------------------------------------------------"
echo "hysteria2 已安装完成"
echo "端口：$PORT，密码：$PASSWORD，伪装域名（SNI）：$SNI"
echo "配置文件：/etc/hysteria/config.yaml"
echo "已设置为随系统自动启动"
echo "查看状态：service hysteria status"
echo "重启服务：service hysteria restart"
echo "------------------------------------------------------------------------"
echo "一键复制粘贴到 v2ray 的订阅链接："
echo "$SUBSCRIPTION_LINK"
echo "------------------------------------------------------------------------"
