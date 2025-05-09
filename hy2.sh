#!/bin/bash

# 输出颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

echo -e "${YELLOW}Hysteria 2 Alpine Linux 安装脚本${NC}"
echo "---------------------------------------"

# --- 依赖包安装 ---
echo -e "${YELLOW}正在安装必要的软件包...${NC}" >&2
apk update >/dev/null
REQUIRED_PKGS="wget curl git openssl openrc lsof coreutils"
for pkg in $REQUIRED_PKGS; do
    if ! apk info -e $pkg &>/dev/null; then
        echo "正在安装 $pkg..." >&2
        if ! apk add $pkg >/dev/null; then
            echo -e "${RED}错误: 安装 $pkg 失败。请手动安装后重试。${NC}" >&2
            exit 1
        fi
    else
        echo "$pkg 已安装。" >&2
    fi
done
echo -e "${GREEN}依赖包安装成功。${NC}" >&2

# --- 辅助函数 ---

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

generate_random_lowercase_string() {
    LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 8
}

get_server_address() {
    local ipv6_ip
    local ipv4_ip

    echo "正在检测服务器公网 IP 地址..." >&2
    ipv6_ip=$(curl -s -m 5 -6 ifconfig.me || curl -s -m 5 -6 ip.sb || curl -s -m 5 -6 api64.ipify.org)
    if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
        echo -e "${GREEN}检测到 IPv6 地址: $ipv6_ip (将优先使用)${NC}" >&2
        echo "[$ipv6_ip]"
        return
    else
        echo -e "${YELLOW}未检测到 IPv6 地址或获取失败。${NC}" >&2
    fi

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

# --- 用户输入 ---
DEFAULT_MASQUERADE_URL="https://www.bing.com"
DEFAULT_PORT="34567"
DEFAULT_ACME_EMAIL="$(generate_random_lowercase_string)@gmail.com"

echo "" >&2
echo -e "${YELLOW}请选择 TLS 验证方式:${NC}" >&2
echo "1. 自定义证书 (适用于已有证书或 NAT VPS 生成自签名证书)" >&2
echo "2. ACME HTTP 验证 (需要域名指向本机IP，且本机80端口可被 Hysteria 使用)" >&2
read -p "请选择 [1-2, 默认 1]: " TLS_TYPE
TLS_TYPE=${TLS_TYPE:-1}

CERT_PATH=""
KEY_PATH=""
DOMAIN=""
SNI=""
ACME_EMAIL=""

case $TLS_TYPE in
    1)
        echo -e "${YELLOW}--- 自定义证书模式 ---${NC}" >&2
        read -p "请输入证书 (.crt) 文件绝对路径 (回车则生成自签名证书): " USER_CERT_PATH
        if [ -z "$USER_CERT_PATH" ]; then
            if ! command -v openssl &>/dev/null; then
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
            CERT_PATH=$(realpath "$USER_CERT_PATH")
            KEY_PATH=$(realpath "$USER_KEY_PATH")
            if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                echo -e "${RED}错误: 提供的证书或私钥文件路径无效或文件不存在。${NC}" >&2
                exit 1
            fi
            SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
            if [ -z "$SNI" ]; then
                read -p "无法从证书自动提取CN(域名)，请输入您希望使用的SNI: " MANUAL_SNI
                [ -z "$MANUAL_SNI" ] && { echo -e "${RED}SNI 不能为空！${NC}" >&2; exit 1; }
                SNI="$MANUAL_SNI"
            else
                echo "从证书中提取到的 SNI (CN): $SNI" >&2
            fi
        fi
        ;;
    2)
        echo -e "${YELLOW}--- ACME HTTP 验证模式 ---${NC}" >&2
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        [ -z "$DOMAIN" ] && { echo -e "${RED}域名不能为空！${NC}" >&2; exit 1; }
        read -p "请输入用于 ACME 证书申请的邮箱 (回车默认 $DEFAULT_ACME_EMAIL): " INPUT_ACME_EMAIL
        ACME_EMAIL=${INPUT_ACME_EMAIL:-$DEFAULT_ACME_EMAIL}
        [ -z "$ACME_EMAIL" ] && { echo -e "${RED}邮箱不能为空！${NC}" >&2; exit 1; }
        SNI=$DOMAIN

        echo "检查 80 端口占用情况..." >&2
        if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then
            echo -e "${YELLOW}警告: 检测到 80 端口已被占用。Hysteria 将尝试使用此端口进行 ACME 验证。${NC}" >&2
            PID_80=$(lsof -t -i:80 -sTCP:LISTEN)
            [ -n "$PID_80" ] && echo "占用80端口的进程 PID(s): $PID_80" >&2
        else
            echo "80 端口未被占用，可用于 ACME HTTP 验证。" >&2
        fi
        ;;
    *)
        echo -e "${RED}无效选项，退出脚本。${NC}" >&2
        exit 1
        ;;
esac

read -p "请输入 Hysteria 端口 (默认 $DEFAULT_PORT): " PORT
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

# --- 下载与权限 ---
HYSTERIA_BIN="/usr/local/bin/hysteria"
echo -e "${YELLOW}正在下载 Hysteria 最新版...${NC}" >&2
ARCH=$(uname -m)
case ${ARCH} in
    x86_64) HYSTERIA_ARCH="amd64";;
    aarch64) HYSTERIA_ARCH="arm64";;
    armv7l) HYSTERIA_ARCH="arm";;
    *) echo -e "${RED}不支持的系统架构: ${ARCH}${NC}" >&2; exit 1;;
esac
if ! wget -qO "$HYSTERIA_BIN" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
    echo -e "${RED}下载 Hysteria 失败，请检查网络或手动下载。${NC}" >&2; exit 1
fi
chmod +x "$HYSTERIA_BIN"
echo -e "${GREEN}Hysteria 下载并设置权限完成: $HYSTERIA_BIN${NC}" >&2

if [ "$TLS_TYPE" -eq 2 ]; then
    echo "为 Hysteria 二进制文件设置 cap_net_bind_service 权限..." >&2
    command -v setcap &>/dev/null || apk add libcap --no-cache >/dev/null
    setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN" &>/dev/null \
        && echo -e "${GREEN}setcap 成功。${NC}" >&2 \
        || echo -e "${RED}setcap 失败。ACME HTTP 验证可能无法工作。${NC}" >&2
fi

# --- 生成 config.yaml ---
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
        echo -e "${YELLOW}注意: 使用自定义证书时，客户端需要设置 'insecure: true'${NC}" >&2
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
esac
echo -e "${GREEN}配置文件生成完毕。${NC}" >&2

# --- 创建 OpenRC 服务（关键改进点）---
echo -e "${YELLOW}创建具备自动重启能力的OpenRC服务...${NC}" >&2
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log"

# 自动重启配置
supervisor="supervise"
respawn_max=0         # 无限次重启
respawn_delay=5       # 重启间隔(秒)
respawn_period=30     # 监控周期(秒)

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
  supervise-daemon --start \
    --name "\$name" \
    --pidfile "\$pidfile" \
    --stdout "\$output_log" \
    --stderr "\$error_log" \
    --exec "\$command" -- \$command_args
  eend \$?
}

stop() {
  ebegin "Stopping \$name"
  supervise-daemon --stop \
    --pidfile "\$pidfile" \
    --exec "\$command"
  eend \$?
}
EOF
chmod +x /etc/init.d/hysteria
echo -e "${GREEN}OpenRC 服务配置成功。${NC}" >&2

# --- 服务管理 ---
echo -e "${YELLOW}启用并启动服务...${NC}" >&2
rc-update add hysteria default >/dev/null
service hysteria stop >/dev/null 2>&1

if ! service hysteria start; then
    echo -e "${RED}服务启动失败！错误日志：${NC}" >&2
    tail -n 10 /var/log/hysteria.error.log >&2
    exit 1
fi

echo -e "${GREEN}服务已成功启动！${NC}" >&2

# --- 显示配置信息 ---
SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${LINK_ADDRESS}:${PORT}/?sni=${LINK_SNI}&alpn=h3&insecure=${LINK_INSECURE}#Hysteria-${SNI}"

cat << EOF

------------------------------------------------------------------------
${GREEN}Hysteria 2 安装完成！${NC}
------------------------------------------------------------------------
服务状态：$(service hysteria status | awk '/status:/{print $2}')
自动重启：已启用（崩溃后5秒自动恢复）
服务器地址: $LINK_ADDRESS
端口: $PORT
密码: $PASSWORD
SNI: $LINK_SNI
伪装站点: $MASQUERADE_URL
------------------------------------------------------------------------
订阅链接：
$SUBSCRIPTION_LINK
------------------------------------------------------------------------
管理命令：
启动服务：service hysteria start
停止服务：service hysteria stop
查看状态：service hysteria status
实时日志：tail -f /var/log/hysteria.log
错误日志：tail -f /var/log/hysteria.error.log
------------------------------------------------------------------------
EOF

# 可选：生成二维码
if command -v qrencode &>/dev/null; then
    echo -e "${YELLOW}订阅链接二维码：${NC}"
    qrencode -t ANSIUTF8 "$SUBSCRIPTION_LINK"
else
    echo -e "${YELLOW}提示: 安装 qrencode 可显示二维码 (apk add qrencode)${NC}"
fi
