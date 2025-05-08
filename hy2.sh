#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Hysteria 2 Installer for Alpine Linux${NC}"
echo "---------------------------------------"

# --- Prerequisite Installation ---
echo -e "${YELLOW}Installing necessary packages...${NC}"
apk update >/dev/null
REQUIRED_PKGS="wget curl git openssh openssl openrc lsof coreutils" # coreutils for 'realpath'
for pkg in $REQUIRED_PKGS; do
    if ! apk info -e $pkg &>/dev/null; then
        echo "Installing $pkg..."
        if ! apk add $pkg; then
            echo -e "${RED}Error: Failed to install $pkg. Please install it manually and retry.${NC}"
            exit 1
        fi
    else
        echo "$pkg is already installed."
    fi
done
echo -e "${GREEN}Dependencies installed successfully.${NC}"

# --- Helper Functions ---

# Generate符合RFC 4122的UUIDv4函数
generate_uuid() {
    local bytes=$(od -x -N 16 /dev/urandom | head -1 | awk '{OFS=""; $1=""; print}')
    local byte7=${bytes:12:4}
    byte7=$((0x${byte7} & 0x0fff | 0x4000))
    byte7=$(printf "%04x" $byte7)
    local byte9=${bytes:20:4}
    byte9=$((0x${byte9} & 0x3fff | 0x8000))
    byte9=$(printf "%04x" $byte9)
    echo "${bytes:0:8}-${bytes:8:4}-${byte7}-${byte9}-${bytes:24:12}" | tr '[:upper:]' '[:lower:]'
}

# 获取服务器地址并格式化
get_server_address() {
    local ip
    # Try IPv4 first
    ip=$(curl -s -4 ifconfig.me)
    if [ -z "$ip" ]; then
        # Try IPv6 if IPv4 fails
        ip=$(curl -s -6 ifconfig.me)
        if [ -z "$ip" ]; then
            echo -e "${RED}无法获取服务器 IP 地址，请检查网络连接。${NC}"
            exit 1
        fi
    fi

    if [[ "$ip" == *":"* ]]; then # IPv6
        echo "[$ip]"
    else # IPv4
        echo "$ip"
    fi
}

# --- User Inputs ---
DEFAULT_MASQUERADE_URL="https://www.bing.com"
DEFAULT_PORT="34567"

echo ""
echo -e "${YELLOW}请选择 TLS 验证方式:${NC}"
echo "1. 自定义证书 (适用于已有证书或 NAT VPS 生成自签名证书)"
echo "2. ACME HTTP 验证 (需要域名指向本机IP，且本机80端口可被 Hysteria 使用)"
echo "3. Cloudflare DNS 验证 (需要域名由 Cloudflare 解析，并提供 API Token)"
read -p "请选择 [1-3, 默认 1]: " TLS_TYPE
TLS_TYPE=${TLS_TYPE:-1}

# Initialize variables
CERT_PATH=""
KEY_PATH=""
DOMAIN=""
SNI=""
EMAIL=""
CF_TOKEN=""
ACME_EMAIL="user@example.com" # Default ACME email, user will be prompted

case $TLS_TYPE in
    1)
        echo -e "${YELLOW}--- 自定义证书模式 ---${NC}"
        read -p "请输入证书 (.crt) 文件绝对路径 (留空则生成自签名证书): " USER_CERT_PATH
        if [ -z "$USER_CERT_PATH" ]; then
            if ! command -v openssl &> /dev/null; then
                echo -e "${RED}错误: openssl 未安装，请手动运行 'apk add openssl' 后重试${NC}"
                exit 1
            fi
            read -p "请输入用于自签名证书的伪装域名 (默认 www.bing.com): " SELF_SIGN_SNI
            SELF_SIGN_SNI=${SELF_SIGN_SNI:-"www.bing.com"}
            SNI="$SELF_SIGN_SNI"
            
            mkdir -p /etc/hysteria/certs
            CERT_PATH="/etc/hysteria/certs/server.crt"
            KEY_PATH="/etc/hysteria/certs/server.key"
            echo "正在生成自签名证书..."
            if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$KEY_PATH" -out "$CERT_PATH" \
                -subj "/CN=$SNI" -days 36500; then
                echo -e "${RED}错误: 自签名证书生成失败，请检查 openssl 配置！${NC}"
                exit 1
            fi
            echo -e "${GREEN}自签名证书已生成: $CERT_PATH, $KEY_PATH${NC}"
        else
            read -p "请输入私钥 (.key) 文件绝对路径: " USER_KEY_PATH
            # Get absolute paths
            CERT_PATH=$(realpath "$USER_CERT_PATH")
            KEY_PATH=$(realpath "$USER_KEY_PATH")

            if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                echo -e "${RED}错误: 提供的证书或私钥文件路径无效或文件不存在。${NC}"
                exit 1
            fi
            # Try to extract SNI from certificate
            SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
            if [ -z "$SNI" ]; then
                 read -p "无法从证书自动提取CN(域名)，请输入您希望使用的SNI: " MANUAL_SNI
                 if [ -z "$MANUAL_SNI" ]; then
                    echo -e "${RED}SNI 不能为空！${NC}"
                    exit 1
                 fi
                 SNI="$MANUAL_SNI"
            else
                echo "从证书中提取到的 SNI (CN): $SNI"
            fi
        fi
        ;;
    2)
        echo -e "${YELLOW}--- ACME HTTP 验证模式 ---${NC}"
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空！${NC}"
            exit 1
        fi
        read -p "请输入用于 ACME 证书申请的邮箱 (例如: admin@$DOMAIN): " ACME_EMAIL
        if [ -z "$ACME_EMAIL" ]; then
            echo -e "${RED}邮箱不能为空！${NC}"
            exit 1
        fi
        SNI=$DOMAIN

        echo "检查 80 端口占用情况..."
        if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then
            echo -e "${YELLOW}警告: 检测到 80 端口已被占用。Hysteria 将尝试使用此端口进行 ACME 验证。${NC}"
            echo "如果 Hysteria 启动失败，请确保没有其他服务 (如nginx, apache) 占用80端口，或者改用 DNS 验证。"
            PID_80=$(lsof -t -i:80 -sTCP:LISTEN)
            if [ -n "$PID_80" ]; then
                 echo "占用80端口的进程 PID(s): $PID_80"
                 # Optionally offer to kill, but better to inform first
                 # read -p "是否尝试停止占用80端口的进程? (y/N): " KILL_CHOICE
                 # if [[ "$KILL_CHOICE" == "y" || "$KILL_CHOICE" == "Y" ]]; then
                 #    kill -9 $PID_80 && echo "进程已尝试停止。" || echo "停止进程失败。"
                 # fi
            fi
        else
            echo "80 端口未被占用，可用于 ACME HTTP 验证。"
        fi
        echo "为 Hysteria 二进制文件设置 cap_net_bind_service 权限以允许绑定到80端口..."
        # Download Hysteria first to setcap, or setcap later after download
        # We'll do it after download for simplicity here.
        ;;
    3)
        echo -e "${YELLOW}--- Cloudflare DNS 验证模式 ---${NC}"
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空！${NC}"
            exit 1
        fi
        read -p "请输入用于 ACME 证书申请的邮箱 (例如: admin@$DOMAIN): " ACME_EMAIL
        if [ -z "$ACME_EMAIL" ]; then
            echo -e "${RED}邮箱不能为空！${NC}"
            exit 1
        fi
        read -p "请输入您的 Cloudflare API Token (具有 Zone.DNS 编辑权限): " CF_TOKEN
        if [ -z "$CF_TOKEN" ]; then
            echo -e "${RED}Cloudflare API Token 不能为空！${NC}"
            exit 1
        fi
        SNI=$DOMAIN
        ;;
    *)
        echo -e "${RED}无效选项，退出脚本。${NC}"
        exit 1
        ;;
esac

read -p "请输入 Hysteria 监听端口 (默认 $DEFAULT_PORT): " PORT
PORT=${PORT:-$DEFAULT_PORT}

read -p "请输入 Hysteria 密码 (回车则使用随机UUID): " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(generate_uuid)
  echo "使用随机密码: $PASSWORD"
fi

read -p "请输入伪装访问的目标URL (默认 $DEFAULT_MASQUERADE_URL): " MASQUERADE_URL
MASQUERADE_URL=${MASQUERADE_URL:-$DEFAULT_MASQUERADE_URL}

SERVER_PUBLIC_ADDRESS=$(get_server_address)
mkdir -p /etc/hysteria

# --- Hysteria Binary Download and Permissions ---
HYSTERIA_BIN="/usr/local/bin/hysteria"
echo -e "${YELLOW}正在下载 Hysteria 最新版...${NC}"
# Determine architecture
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)
        HYSTERIA_ARCH="amd64"
        ;;
    aarch64)
        HYSTERIA_ARCH="arm64"
        ;;
    # Add other architectures if needed, e.g. armv7
    *)
        echo -e "${RED}不支持的系统架构: ${ARCH}${NC}"
        exit 1
        ;;
esac

if ! wget -qO "$HYSTERIA_BIN" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
    echo -e "${RED}下载 Hysteria 失败，请检查网络或手动下载。${NC}"
    exit 1
fi
chmod +x "$HYSTERIA_BIN"
echo -e "${GREEN}Hysteria 下载并设置权限完成: $HYSTERIA_BIN${NC}"

if [ "$TLS_TYPE" -eq 2 ]; then
    echo "为 Hysteria 二进制文件设置 cap_net_bind_service 权限..."
    if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN"; then
        echo -e "${RED}错误: setcap 失败。ACME HTTP 验证可能无法工作。请确保已安装 libcap (apk add libcap).${NC}"
        # apk add libcap if not present, then retry
        if ! apk info -e libcap &>/dev/null; then
            echo "尝试安装 libcap..."
            apk add libcap
            if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN"; then
                 echo -e "${RED}再次 setcap 失败。请手动执行 setcap 'cap_net_bind_service=+ep' $HYSTERIA_BIN ${NC}"
            else
                 echo -e "${GREEN}setcap 成功。${NC}"
            fi
        fi
    else
        echo -e "${GREEN}setcap 成功。${NC}"
    fi
fi


# --- Generate Hysteria config.yaml ---
echo -e "${YELLOW}正在生成配置文件 /etc/hysteria/config.yaml...${NC}"
cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true # Important for SNI consistency with masquerade target
EOF

# TLS/ACME specific configuration
case $TLS_TYPE in
    1)
        cat >> /etc/hysteria/config.yaml << EOF
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
        # If self-signed, SNI might be different from actual domain, use specified SNI
        LINK_SNI="$SNI"
        LINK_ADDRESS="$SERVER_PUBLIC_ADDRESS" # For self-signed, typically use IP
        LINK_INSECURE=1 # Self-signed certs are insecure by default for clients
        # For user-provided valid cert, user might want to use domain and secure=0
        # We'll assume if custom cert is provided, it might be for an IP or internal domain.
        # If they have a valid cert for a public domain, they'd likely use ACME.
        # To be safe, if it's not a known ACME domain, mark insecure=1 or let user choose.
        # For simplicity here: self-signed is insecure=1. User-provided custom, assume insecure=1 unless SNI is a public domain.
        # This part can be made more nuanced. For now, custom cert -> insecure=1 is safer.
        echo -e "${YELLOW}注意: 使用自定义证书时，客户端可能需要设置 'insecure: true' (对应链接中 insecure=1)${NC}"

        ;;
    2)
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
  # Hysteria will handle the HTTP-01 challenge on port 80
EOF
        LINK_SNI="$DOMAIN"
        LINK_ADDRESS="$DOMAIN" # For ACME, always use the domain
        LINK_INSECURE=0
        ;;
    3)
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
  dns:
    provider: cloudflare
    cloudflare_api_token: "$CF_TOKEN" # Important to quote if token has special chars
EOF
        LINK_SNI="$DOMAIN"
        LINK_ADDRESS="$DOMAIN" # For ACME, always use the domain
        LINK_INSECURE=0
        ;;
esac
echo -e "${GREEN}配置文件生成完毕。${NC}"

# --- Create OpenRC Service File ---
echo -e "${YELLOW}正在创建 OpenRC 服务文件 /etc/init.d/hysteria...${NC}"
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
command_background="yes"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log" # Separate error log

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -f \$output_log -m 0644 -o hysteria:hysteria
  checkpath -f \$error_log -m 0644 -o hysteria:hysteria
  # Ensure /var/run exists and is writable, OpenRC usually handles this
  # checkpath -d /var/run
}

start() {
  ebegin "Starting \$name"
  start-stop-daemon --start --quiet --background \\
    --make-pidfile --pidfile \$pidfile \\
    --stdout \$output_log --stderr \$error_log \\
    --exec \$command -- \$command_args
  eend \$?
}

stop() {
    ebegin "Stopping \$name"
    start-stop-daemon --stop --quiet --pidfile \$pidfile
    eend \$?
}

# restart is handled by openrc calling stop then start
EOF

chmod +x /etc/init.d/hysteria
# Create a hysteria user/group for logging, if desired, or chown to root.
# For simplicity, logs will be owned by root unless hysteria user is created and specified in checkpath.
# To keep it simple for now, removing -o hysteria:hysteria. Root will own logs.
sed -i 's/ -o hysteria:hysteria//g' /etc/init.d/hysteria

echo -e "${GREEN}OpenRC 服务文件创建成功。${NC}"

# --- Enable and Start Service ---
echo -e "${YELLOW}正在启用并启动 Hysteria 服务...${NC}"
rc-update add hysteria default
service hysteria stop >/dev/null 2>&1 # Stop if already running from a previous attempt
service hysteria start

# Wait a few seconds for the service to potentially log errors
sleep 5

# --- Display Results ---
if service hysteria status | grep -q "started"; then
    echo -e "${GREEN}Hysteria 服务已成功启动！${NC}"
else
    echo -e "${RED}Hysteria 服务启动失败。请检查日志:${NC}"
    echo "  日志: tail -n 20 /var/log/hysteria.log"
    echo "  错误: tail -n 20 /var/log/hysteria.error.log"
    echo "  配置: cat /etc/hysteria/config.yaml"
    echo "请根据错误信息调整配置或环境后，使用 'service hysteria restart' 重启服务。"
    # Optionally, exit here if start failed.
fi

# Generate subscription link
# Ensure LINK_ADDRESS doesn't have brackets for the hysteria2 URL scheme if it's an IPv6
URL_HOST_PART="$LINK_ADDRESS"
if [[ "$URL_HOST_PART" == "["* ]]; then # If it's like [ipv6_addr]
    URL_HOST_PART=$(echo "$URL_HOST_PART" | tr -d '[]')
fi

SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${URL_HOST_PART}:${PORT}/?sni=${LINK_SNI}&alpn=h3&insecure=${LINK_INSECURE}#Hysteria-${SNI}" # Added a more descriptive fragment

echo ""
echo "------------------------------------------------------------------------"
echo -e "${GREEN}Hysteria 2 安装和配置完成！${NC}"
echo "------------------------------------------------------------------------"
echo "服务器地址 (用于客户端配置): $LINK_ADDRESS"
echo "端口: $PORT"
echo "密码: $PASSWORD"
echo "SNI / 伪装域名: $LINK_SNI"
echo "伪装目标站点: $MASQUERADE_URL"
echo "TLS 模式: $TLS_TYPE (1:Custom, 2:ACME-HTTP, 3:Cloudflare-DNS)"
if [ "$TLS_TYPE" -eq 1 ]; then
    echo "证书路径: $CERT_PATH"
    echo "私钥路径: $KEY_PATH"
fi
echo "客户端 insecure (0=false, 1=true): $LINK_INSECURE"
echo "------------------------------------------------------------------------"
echo -e "${YELLOW}订阅链接 (Hysteria V2):${NC}"
echo "$SUBSCRIPTION_LINK"
echo "------------------------------------------------------------------------"

# Optional: QR Code
if command -v qrencode &> /dev/null; then
    echo -e "${YELLOW}订阅链接二维码:${NC}"
    qrencode -t ANSIUTF8 "$SUBSCRIPTION_LINK"
else
    echo -e "${YELLOW}提示: 安装 'qrencode' (apk add qrencode) 后可显示二维码。${NC}"
fi
echo "------------------------------------------------------------------------"
echo "管理命令:"
echo "  service hysteria start   - 启动服务"
echo "  service hysteria stop    - 停止服务"
echo "  service hysteria restart - 重启服务"
echo "  service hysteria status  - 查看状态"
echo "  cat /etc/hysteria/config.yaml - 查看配置文件"
echo "  tail -f /var/log/hysteria.log - 查看实时日志"
echo "  tail -f /var/log/hysteria.error.log - 查看实时错误日志"
echo "------------------------------------------------------------------------"
