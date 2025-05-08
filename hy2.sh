#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' 

echo -e "${YELLOW}Hysteria 2 Installer for Alpine Linux${NC}"
echo "---------------------------------------"

echo -e "${YELLOW}Installing necessary packages...${NC}" >&2
apk update >/dev/null
REQUIRED_PKGS="wget curl git openssl openrc lsof coreutils"
for pkg in $REQUIRED_PKGS; do
    if ! apk info -e $pkg &>/dev/null; then
        echo "Installing $pkg..." >&2
        if ! apk add $pkg; then
            echo -e "${RED}Error: Failed to install $pkg. Please install it manually and retry.${NC}" >&2
            exit 1
        fi
    else
        echo "$pkg is already installed." >&2
    fi
done
echo -e "${GREEN}Dependencies installed successfully.${NC}" >&2

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

# 获取服务器地址并格式化, 优先 IPv6
get_server_address() {
    local ipv6_ip
    local ipv4_ip

    echo "正在检测服务器公网 IP 地址..." >&2 

    echo "尝试获取 IPv6 地址..." >&2 
    ipv6_ip=$(curl -s -m 5 -6 ifconfig.me || curl -s -m 5 -6 ip.sb || curl -s -m 5 -6 api64.ipify.org)
    if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
        echo -e "${GREEN}检测到 IPv6 地址: $ipv6_ip (将优先使用)${NC}" >&2 
        echo "[$ipv6_ip]"
        return
    else
        echo -e "${YELLOW}未检测到 IPv6 地址或获取失败。${NC}" >&2 
    fi

    echo "尝试获取 IPv4 地址..." >&2 
    ipv4_ip=$(curl -s -m 5 -4 ifconfig.me || curl -s -m 5 -4 ip.sb || curl -s -m 5 -4 api.ipify.org)
    if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then
        echo -e "${GREEN}检测到 IPv4 地址: $ipv4_ip${NC}" >&2 
        echo "$ipv4_ip"
        return
    else
        echo -e "${YELLOW}未检测到 IPv4 地址或获取失败。${NC}" >&2 
    fi

    echo -e "${RED}错误: 无法获取服务器公网 IP 地址 (IPv4 或 IPv6)。请检查网络连接。${NC}" >&2 
    exit 1
}


DEFAULT_MASQUERADE_URL="https://www.bing.com"
DEFAULT_PORT="34567"

echo "" >&2
echo -e "${YELLOW}请选择 TLS 验证方式:${NC}" >&2
echo "1. 自定义证书 (适用于已有证书或 NAT VPS 生成自签名证书)" >&2
echo "2. ACME HTTP 验证 (需要域名指向本机IP，且本机80端口可被 Hysteria 使用)" >&2
echo "3. Cloudflare DNS 验证 (需要域名由 Cloudflare 解析，并提供 API Token)" >&2
read -p "请选择 [1-3, 默认 1]: " TLS_TYPE
TLS_TYPE=${TLS_TYPE:-1}


CERT_PATH=""
KEY_PATH=""
DOMAIN=""
SNI=""
EMAIL=""
CF_TOKEN=""
ACME_EMAIL="user@example.com" 

case $TLS_TYPE in
    1)
        echo -e "${YELLOW}--- 自定义证书模式 ---${NC}" >&2
        read -p "请输入证书 (.crt) 文件绝对路径 (留空则生成自签名证书): " USER_CERT_PATH
        if [ -z "$USER_CERT_PATH" ]; then
            if ! command -v openssl &> /dev/null; then
                echo -e "${RED}错误: openssl 未安装，请手动运行 'apk add openssl' 后重试${NC}" >&2
                exit 1
            fi
            read -p "请输入用于自签名证书的伪装域名 (默认 www.bing.com): " SELF_SIGN_SNI
            SELF_SIGN_SNI=${SELF_SIGN_SNI:-"www.bing.com"}
            SNI="$SELF_SIGN_SNI"
            
            mkdir -p /etc/hysteria/certs
            CERT_PATH="/etc/hysteria/certs/server.crt"
            KEY_PATH="/etc/hysteria/certs/server.key"
            echo "正在生成自签名证书..." >&2
            if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$KEY_PATH" -out "$CERT_PATH" \
                -subj "/CN=$SNI" -days 36500; then
                echo -e "${RED}错误: 自签名证书生成失败，请检查 openssl 配置！${NC}" >&2
                exit 1
            fi
            echo -e "${GREEN}自签名证书已生成: $CERT_PATH, $KEY_PATH${NC}" >&2
        else
            read -p "请输入私钥 (.key) 文件绝对路径: " USER_KEY_PATH
            if [ -z "$USER_CERT_PATH" ] || [ -z "$USER_KEY_PATH" ]; then
                 echo -e "${RED}错误: 证书和私钥路径都不能为空。${NC}" >&2
                 exit 1
            fi
          
            CERT_PATH=$(realpath "$USER_CERT_PATH")
            KEY_PATH=$(realpath "$USER_KEY_PATH")

            if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                echo -e "${RED}错误: 提供的证书或私钥文件路径无效或文件不存在。${NC}" >&2
                exit 1
            fi
      
            SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
            if [ -z "$SNI" ]; then
                 read -p "无法从证书自动提取CN(域名)，请输入您希望使用的SNI: " MANUAL_SNI
                 if [ -z "$MANUAL_SNI" ]; then
                    echo -e "${RED}SNI 不能为空！${NC}" >&2
                    exit 1
                 fi
                 SNI="$MANUAL_SNI"
            else
                echo "从证书中提取到的 SNI (CN): $SNI" >&2
            fi
        fi
        ;;
    2)
        echo -e "${YELLOW}--- ACME HTTP 验证模式 ---${NC}" >&2
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空！${NC}" >&2
            exit 1
        fi
        read -p "请输入用于 ACME 证书申请的邮箱 (例如: admin@$DOMAIN): " ACME_EMAIL
        if [ -z "$ACME_EMAIL" ]; then
            echo -e "${RED}邮箱不能为空！${NC}" >&2
            exit 1
        fi
        SNI=$DOMAIN

        echo "检查 80 端口占用情况..." >&2
        if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then
            echo -e "${YELLOW}警告: 检测到 80 端口已被占用。Hysteria 将尝试使用此端口进行 ACME 验证。${NC}" >&2
            echo "如果 Hysteria 启动失败，请确保没有其他服务 (如nginx, apache) 占用80端口，或者改用 DNS 验证。" >&2
            PID_80=$(lsof -t -i:80 -sTCP:LISTEN)
            if [ -n "$PID_80" ]; then
                 echo "占用80端口的进程 PID(s): $PID_80" >&2
            fi
        else
            echo "80 端口未被占用，可用于 ACME HTTP 验证。" >&2
        fi
     
        ;;
    3)
        echo -e "${YELLOW}--- Cloudflare DNS 验证模式 ---${NC}" >&2
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then
            echo -e "${RED}域名不能为空！${NC}" >&2
            exit 1
        fi
        read -p "请输入用于 ACME 证书申请的邮箱 (例如: admin@$DOMAIN): " ACME_EMAIL
        if [ -z "$ACME_EMAIL" ]; then
            echo -e "${RED}邮箱不能为空！${NC}" >&2
            exit 1
        fi
        read -p "请输入您的 Cloudflare API Token (具有 Zone.DNS 编辑权限): " CF_TOKEN
        if [ -z "$CF_TOKEN" ]; then
            echo -e "${RED}Cloudflare API Token 不能为空！${NC}" >&2
            exit 1
        fi
        SNI=$DOMAIN
        ;;
    *)
        echo -e "${RED}无效选项，退出脚本。${NC}" >&2
        exit 1
        ;;
esac

read -p "请输入 Hysteria 监听端口 (默认 $DEFAULT_PORT): " PORT
PORT=${PORT:-$DEFAULT_PORT}

read -p "请输入 Hysteria 密码 (回车则使用随机UUID): " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(generate_uuid)
  echo "使用随机密码: $PASSWORD" >&2
fi

read -p "请输入伪装访问的目标URL (默认 $DEFAULT_MASQUERADE_URL): " MASQUERADE_URL
MASQUERADE_URL=${MASQUERADE_URL:-$DEFAULT_MASQUERADE_URL}


SERVER_PUBLIC_ADDRESS=$(get_server_address) 

mkdir -p /etc/hysteria

HYSTERIA_BIN="/usr/local/bin/hysteria"
echo -e "${YELLOW}正在下载 Hysteria 最新版...${NC}" >&2
ARCH=$(uname -m)
case ${ARCH} in
    x86_64)
        HYSTERIA_ARCH="amd64"
        ;;
    aarch64)
        HYSTERIA_ARCH="arm64"
        ;;
    armv7l) 
        HYSTERIA_ARCH="arm"
        ;;
    *)
        echo -e "${RED}不支持的系统架构: ${ARCH}${NC}" >&2
        exit 1
        ;;
esac

if ! wget -qO "$HYSTERIA_BIN" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
    echo -e "${RED}下载 Hysteria 失败，请检查网络或手动下载。${NC}" >&2
    exit 1
fi
chmod +x "$HYSTERIA_BIN"
echo -e "${GREEN}Hysteria 下载并设置权限完成: $HYSTERIA_BIN${NC}" >&2

if [ "$TLS_TYPE" -eq 2 ]; then
    echo "为 Hysteria 二进制文件设置 cap_net_bind_service 权限..." >&2
    if ! command -v setcap &>/dev/null; then
        echo -e "${YELLOW}setcap 命令未找到，尝试安装 libcap...${NC}" >&2
        apk add libcap --no-cache
    fi

    if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN"; then
        echo -e "${RED}错误: setcap 失败。ACME HTTP 验证可能无法工作。请确保已安装 libcap 并具有相应权限。${NC}" >&2
    else
        echo -e "${GREEN}setcap 成功。${NC}" >&2
    fi
fi


echo -e "${YELLOW}正在生成配置文件 /etc/hysteria/config.yaml...${NC}" >&2
cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true
EOF

case $TLS_TYPE in
    1)
        cat >> /etc/hysteria/config.yaml << EOF
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
        LINK_SNI="$SNI"
        LINK_ADDRESS="$SERVER_PUBLIC_ADDRESS" 
        LINK_INSECURE=1 
        echo -e "${YELLOW}注意: 使用自定义证书时，客户端通常需要设置 'insecure: true' (对应链接中 insecure=1)${NC}" >&2
        ;;
    2)
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
EOF
        LINK_SNI="$DOMAIN"
        LINK_ADDRESS="$DOMAIN" 
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
    cloudflare_api_token: "$CF_TOKEN"
EOF
        LINK_SNI="$DOMAIN"
        LINK_ADDRESS="$DOMAIN" 
        LINK_INSECURE=0
        ;;
esac
echo -e "${GREEN}配置文件生成完毕。${NC}" >&2


echo -e "${YELLOW}正在创建 OpenRC 服务文件 /etc/init.d/hysteria...${NC}" >&2
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
command_background="yes"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -f \$output_log -m 0644
  checkpath -f \$error_log -m 0644
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
EOF

chmod +x /etc/init.d/hysteria
echo -e "${GREEN}OpenRC 服务文件创建成功。${NC}" >&2


echo -e "${YELLOW}正在启用并启动 Hysteria 服务...${NC}" >&2
rc-update add hysteria default >/dev/null
service hysteria stop >/dev/null 2>&1 
if ! service hysteria start; then
    echo -e "${RED}Hysteria 服务启动失败。请检查以下日志获取错误信息:${NC}" >&2
    echo "  输出日志: tail -n 20 /var/log/hysteria.log" >&2
    echo "  错误日志: tail -n 20 /var/log/hysteria.error.log" >&2
    echo "  配置文件: cat /etc/hysteria/config.yaml" >&2
    echo "请根据错误信息调整配置或环境后，使用 'service hysteria restart' 重启服务。" >&2
    exit 1
fi

echo -e "${GREEN}等待服务启动...${NC}" >&2
sleep 3 


if service hysteria status | grep -q "started"; then
    echo -e "${GREEN}Hysteria 服务已成功启动！${NC}"
else
    echo -e "${RED}Hysteria 服务状态异常。请检查日志:${NC}"
    echo "  输出日志: tail -n 20 /var/log/hysteria.log"
    echo "  错误日志: tail -n 20 /var/log/hysteria.error.log"
    echo "  配置文件: cat /etc/hysteria/config.yaml"
fi

URL_HOST_PART="$LINK_ADDRESS"
if [[ "$URL_HOST_PART" == "["* ]]; then 
    URL_HOST_PART=$(echo "$URL_HOST_PART" | tr -d '[]')
fi

SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${URL_HOST_PART}:${PORT}/?sni=${LINK_SNI}&alpn=h3&insecure=${LINK_INSECURE}#Hysteria-${SNI}"

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
