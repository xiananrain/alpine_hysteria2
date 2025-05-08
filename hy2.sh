#!/bin/bash

# 安装必要的软件包（增加util-linux用于生成UUID）
apk add wget curl git openssh openssl openrc libcap util-linux

# 生成UUID格式密码的函数
generate_uuid_password() {
  uuidgen | tr '[:upper:]' '[:lower:]'  # 生成小写UUID
}

# 提供默认值
read -p "请选择 TLS 验证方式 (1. 自定义证书 2. ACME HTTP 验证 3. Cloudflare DNS 验证) [默认1]: " TLS_TYPE
TLS_TYPE=${TLS_TYPE:-1}

case $TLS_TYPE in
    1)
        # 自定义证书模式
        read -p "请输入证书路径（留空生成自签名证书）: " CERT_PATH
        if [ -z "$CERT_PATH" ]; then
            read -p "请输入伪装域名（默认 www.bing.com）: " SNI
            SNI=${SNI:-www.bing.com}
            mkdir -p /etc/hysteria/
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
                -subj "/CN=$SNI" -days 36500
            CERT_PATH="/etc/hysteria/server.crt"
            KEY_PATH="/etc/hysteria/server.key"
        else
            read -p "请输入私钥路径: " KEY_PATH
            SNI=$(openssl x509 -noout -subject -in $CERT_PATH | awk -F= '{print $NF}' | tr -d ' ')
        fi
        ;;
    2)
        # ACME HTTP 模式
        read -p "请输入域名: " DOMAIN
        SNI=$DOMAIN
        # 检查 80 端口占用并设置权限
        if netstat -tuln | grep -q ':80 '; then
            echo -e "\033[31m检测到 80 端口被占用，尝试释放端口...\033[0m"
            apk add lsof
            PID=$(lsof -t -i:80)
            [ -n "$PID" ] && kill -9 $PID
        fi
        setcap 'cap_net_bind_service=+ep' /usr/local/bin/hysteria
        ;;
    3)
        # Cloudflare DNS 模式
        read -p "请输入域名: " DOMAIN
        read -p "请输入邮箱: " EMAIL
        read -p "请输入 Cloudflare API Token: " CF_TOKEN
        SNI=$DOMAIN
        ;;
    *)
        echo "无效选项，使用自定义证书模式"
        TLS_TYPE=1
        ;;
esac

read -p "请输入端口（默认 34567）: " PORT
PORT=${PORT:-34567}

# 密码处理逻辑
read -p "请输入密码（回车则使用随机UUID）: " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(generate_uuid_password)
fi

# 获取服务器 IP 地址
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
  echo "无法获取服务器 IP 地址，请检查网络连接。"
  exit 1
fi

# 生成 Hysteria config.yaml
echo "正在生成配置文件..."
cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true
EOF

case $TLS_TYPE in
    1)
        cat >> /etc/hysteria/config.yaml << EOF
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
        ;;
    2)
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: admin@$DOMAIN
EOF
        ;;
    3)
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
  dns:
    provider: cloudflare
    cloudflare_api_token: $CF_TOKEN
EOF
        ;;
esac

# 下载 Hysteria 并设置权限
echo "正在下载 Hysteria..."
wget -O /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# 创建服务文件
echo "正在配置服务..."
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
command_background="yes"

depend() {
  need networking
}

start_pre() {
  checkpath -f /var/log/hysteria.log
}

start() {
  ebegin "Starting \$name"
  start-stop-daemon --start --quiet --background \\
    --make-pidfile --pidfile \$pidfile \\
    --exec \$command -- \$command_args &> /var/log/hysteria.log
  eend \$?
}
EOF

chmod +x /etc/init.d/hysteria
rc-update add hysteria
service hysteria start

# 生成订阅链接
case $TLS_TYPE in
    1)
        SERVER_ADDRESS="$SERVER_IP"
        SNI_LINK="$SNI"
        INSECURE=1
        ;;
    2|3)
        SERVER_ADDRESS="$DOMAIN"
        SNI_LINK="$DOMAIN"
        INSECURE=0
        ;;
esac

SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${SERVER_ADDRESS}:${PORT}/?sni=${SNI_LINK}&alpn=h3&insecure=${INSECURE}#hy2"

# 显示结果
echo "------------------------------------------------------------------------"
echo "安装完成！"
echo "服务器地址: $SERVER_ADDRESS"
echo "端口: $PORT"
echo "密码(UUID): $PASSWORD"
echo "SNI: $SNI_LINK"
echo "订阅链接:"
echo "$SUBSCRIPTION_LINK"
echo "------------------------------------------------------------------------"
