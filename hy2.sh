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
        if ! apk add $pkg > /dev/null; then 
            echo -e "${RED}错误: 安装 $pkg 失败。请手动安装后重试。${NC}" >&2
            exit 1
        fi
    else
        echo "$pkg 已安装。" >&2
    fi
done
echo -e "${GREEN}依赖包安装成功。${NC}" >&2

# --- 辅助函数 ---

# 生成符合RFC 4122标准的UUIDv4函数
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

# 生成随机8位小写字母函数
generate_random_lowercase_string() {
    LC_ALL=C tr -dc 'a-z' < /dev/urandom | head -c 8
}

# 获取服务器公网地址并格式化，优先使用IPv6
get_server_address() {
    local ipv6_ip
    local ipv4_ip

    echo "正在检测服务器公网 IP 地址..." >&2 
    # 首先尝试获取IPv6地址
    echo "尝试获取 IPv6 地址..." >&2 
    ipv6_ip=$(curl -s -m 5 -6 ifconfig.me || curl -s -m 5 -6 ip.sb || curl -s -m 5 -6 api64.ipify.org)
    if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then # 检查是否是有效的IPv6地址
        echo -e "${GREEN}检测到 IPv6 地址: $ipv6_ip (将优先使用)${NC}" >&2 
        echo "[$ipv6_ip]" # 这是实际返回给调用者的值，输出到标准输出流
        return
    else
        echo -e "${YELLOW}未检测到 IPv6 地址或获取失败。${NC}" >&2 
    fi

    # 如果未找到IPv6或获取失败，则尝试获取IPv4地址
    echo "尝试获取 IPv4 地址..." >&2
    ipv4_ip=$(curl -s -m 5 -4 ifconfig.me || curl -s -m 5 -4 ip.sb || curl -s -m 5 -4 api.ipify.org)
    if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then # 检查是否是有效的IPv4地址
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
DEFAULT_MASQUERADE_URL="https://www.bing.com" # 默认伪装网址
DEFAULT_PORT="34567"
DEFAULT_ACME_EMAIL="$(generate_random_lowercase_string)@gmail.com" # 默认ACME邮箱

echo "" >&2
echo -e "${YELLOW}请选择 TLS 验证方式:${NC}" >&2
echo "1. 自定义证书 (适用于已有证书或 NAT VPS 生成自签名证书)" >&2
echo "2. ACME HTTP 验证 (需要域名指向本机IP，且本机80端口可被 Hysteria 使用)" >&2
read -p "请选择 [1-2, 默认 1]: " TLS_TYPE
TLS_TYPE=${TLS_TYPE:-1} # 如果用户未输入，则使用默认值1

# 初始化变量
CERT_PATH=""
KEY_PATH=""
DOMAIN=""
SNI=""
ACME_EMAIL="" # ACME申请证书的邮箱

case $TLS_TYPE in
    1) # 自定义证书模式
        echo -e "${YELLOW}--- 自定义证书模式 ---${NC}" >&2
        read -p "请输入证书 (.crt) 文件绝对路径 (留空则生成自签名证书): " USER_CERT_PATH
        if [ -z "$USER_CERT_PATH" ]; then # 如果用户未提供证书路径，则生成自签名证书
            if ! command -v openssl &> /dev/null; then # 检查openssl命令是否存在
                echo -e "${RED}错误: openssl 未安装，请手动运行 'apk add openssl' 后重试${NC}" >&2
                exit 1
            fi
            read -p "请输入用于自签名证书的伪装域名 (默认 www.bing.com): " SELF_SIGN_SNI
            SELF_SIGN_SNI=${SELF_SIGN_SNI:-"www.bing.com"} # 默认自签名SNI
            SNI="$SELF_SIGN_SNI"
            
            mkdir -p /etc/hysteria/certs # 创建证书存放目录
            CERT_PATH="/etc/hysteria/certs/server.crt" # 自签名证书路径
            KEY_PATH="/etc/hysteria/certs/server.key" # 自签名私钥路径
            echo "正在生成自签名证书..." >&2
            if ! openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$KEY_PATH" -out "$CERT_PATH" \
                -subj "/CN=$SNI" -days 36500; then # 生成自签名证书
                echo -e "${RED}错误: 自签名证书生成失败，请检查 openssl 配置！${NC}" >&2
                exit 1
            fi
            echo -e "${GREEN}自签名证书已生成: $CERT_PATH, $KEY_PATH${NC}" >&2
        else # 用户提供了证书路径
            read -p "请输入私钥 (.key) 文件绝对路径: " USER_KEY_PATH
            if [ -z "$USER_CERT_PATH" ] || [ -z "$USER_KEY_PATH" ]; then
                 echo -e "${RED}错误: 证书和私钥路径都不能为空。${NC}" >&2
                 exit 1
            fi
            # 获取文件的绝对路径
            CERT_PATH=$(realpath "$USER_CERT_PATH")
            KEY_PATH=$(realpath "$USER_KEY_PATH")

            if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then # 检查文件是否存在
                echo -e "${RED}错误: 提供的证书或私钥文件路径无效或文件不存在。${NC}" >&2
                exit 1
            fi
            # 尝试从证书中提取SNI (Common Name)
            SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
            if [ -z "$SNI" ]; then # 如果无法自动提取SNI
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
    2) # ACME HTTP 验证模式
        echo -e "${YELLOW}--- ACME HTTP 验证模式 ---${NC}" >&2
        read -p "请输入您的域名 (例如: example.com): " DOMAIN
        if [ -z "$DOMAIN" ]; then echo -e "${RED}域名不能为空！${NC}" >&2; exit 1; fi
        read -p "请输入用于 ACME 证书申请的邮箱 (默认 $DEFAULT_ACME_EMAIL): " INPUT_ACME_EMAIL
        ACME_EMAIL=${INPUT_ACME_EMAIL:-$DEFAULT_ACME_EMAIL} # 如果用户未输入，则使用默认ACME邮箱
        if [ -z "$ACME_EMAIL" ]; then echo -e "${RED}邮箱不能为空！${NC}" >&2; exit 1; fi # 再次检查，防止默认值生成失败
        SNI=$DOMAIN # ACME模式下，SNI与域名相同

        echo "检查 80 端口占用情况..." >&2
        if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then # 检查80端口是否被占用
            echo -e "${YELLOW}警告: 检测到 80 端口已被占用。Hysteria 将尝试使用此端口进行 ACME 验证。${NC}" >&2
            echo "如果 Hysteria 启动失败，请确保没有其他服务 (如nginx, apache) 占用80端口。" >&2
            PID_80=$(lsof -t -i:80 -sTCP:LISTEN) # 获取占用80端口的进程ID
            [ -n "$PID_80" ] && echo "占用80端口的进程 PID(s): $PID_80" >&2
        else
            echo "80 端口未被占用，可用于 ACME HTTP 验证。" >&2
        fi
        # setcap权限将在Hysteria二进制文件下载后设置
        ;;
    *) # 无效选项
        echo -e "${RED}无效选项，退出脚本。${NC}" >&2
        exit 1
        ;;
esac

read -p "请输入 Hysteria 监听端口 (默认 $DEFAULT_PORT): " PORT
PORT=${PORT:-$DEFAULT_PORT} # 如果用户未输入，则使用默认端口

read -p "请输入 Hysteria 密码 (回车则使用随机UUID): " PASSWORD
if [ -z "$PASSWORD" ]; then
  PASSWORD=$(generate_uuid) # 如果用户未输入，则生成随机UUID作为密码
  echo "使用随机密码: $PASSWORD" >&2
fi

read -p "请输入伪装访问的目标URL (默认 $DEFAULT_MASQUERADE_URL): " MASQUERADE_URL
MASQUERADE_URL=${MASQUERADE_URL:-$DEFAULT_MASQUERADE_URL} # 如果用户未输入，则使用默认伪装URL

SERVER_PUBLIC_ADDRESS=$(get_server_address) # 获取服务器公网IP (优先IPv6)

mkdir -p /etc/hysteria # 创建Hysteria配置目录

# --- Hysteria 二进制文件下载与权限设置 ---
HYSTERIA_BIN="/usr/local/bin/hysteria" # Hysteria二进制文件路径
echo -e "${YELLOW}正在下载 Hysteria 最新版...${NC}" >&2
ARCH=$(uname -m) # 获取系统架构
case ${ARCH} in
    x86_64) HYSTERIA_ARCH="amd64";;
    aarch64) HYSTERIA_ARCH="arm64";;
    armv7l) HYSTERIA_ARCH="arm";; # 兼容armv7架构
    *) echo -e "${RED}不支持的系统架构: ${ARCH}${NC}" >&2; exit 1;;
esac

# 下载Hysteria二进制文件
if ! wget -qO "$HYSTERIA_BIN" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
    echo -e "${RED}下载 Hysteria 失败，请检查网络或手动下载。${NC}" >&2; exit 1
fi
chmod +x "$HYSTERIA_BIN" # 赋予执行权限
echo -e "${GREEN}Hysteria 下载并设置权限完成: $HYSTERIA_BIN${NC}" >&2

# 如果是ACME HTTP模式，为Hysteria设置绑定低端口（如80）的权限
if [ "$TLS_TYPE" -eq 2 ]; then
    echo "为 Hysteria 二进制文件设置 cap_net_bind_service 权限..." >&2
    if ! command -v setcap &>/dev/null; then # 检查setcap命令是否存在
        echo -e "${YELLOW}setcap 命令未找到，尝试安装 libcap...${NC}" >&2
        apk add libcap --no-cache >/dev/null # 安装libcap包
    fi
    if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN"; then # 设置权限
        echo -e "${RED}错误: setcap 失败。ACME HTTP 验证可能无法工作。${NC}" >&2
    else
        echo -e "${GREEN}setcap 成功。${NC}" >&2
    fi
fi

# --- 生成 Hysteria 配置文件 config.yaml ---
echo -e "${YELLOW}正在生成配置文件 /etc/hysteria/config.yaml...${NC}" >&2
cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT # 监听地址和端口
auth:
  type: password
  password: $PASSWORD # 认证方式及密码
masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL # 伪装配置
    rewriteHost: true # 是否重写Host头，通常为true
EOF

# 根据选择的TLS类型，追加相应的TLS/ACME配置
case $TLS_TYPE in
    1) # 自定义证书
        cat >> /etc/hysteria/config.yaml << EOF
tls:
  cert: $CERT_PATH # 证书路径
  key: $KEY_PATH   # 私钥路径
EOF
        LINK_SNI="$SNI" # 订阅链接中的SNI
        LINK_ADDRESS="$SERVER_PUBLIC_ADDRESS" # 订阅链接中的服务器地址
        LINK_INSECURE=1 # 自定义证书（尤其是自签名）通常需要客户端设置insecure=true
        echo -e "${YELLOW}注意: 使用自定义证书时，客户端通常需要设置 'insecure: true'${NC}" >&2
        ;;
    2) # ACME HTTP
        cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN # 申请证书的域名
  email: $ACME_EMAIL # 申请证书的邮箱
  # Hysteria将自动在80端口处理HTTP-01质询
EOF
        LINK_SNI="$DOMAIN"; LINK_ADDRESS="$DOMAIN"; LINK_INSECURE=0 # ACME证书是受信任的
        ;;
esac
echo -e "${GREEN}配置文件生成完毕。${NC}" >&2

# --- 创建 OpenRC 服务文件 ---
echo -e "${YELLOW}正在创建 OpenRC 服务文件 /etc/init.d/hysteria...${NC}" >&2
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run
name="hysteria" # 服务名称
command="/usr/local/bin/hysteria" # Hysteria可执行文件路径
command_args="server --config /etc/hysteria/config.yaml" # Hysteria启动参数
pidfile="/var/run/\${name}.pid" # PID文件路径
command_background="yes" # 后台运行
output_log="/var/log/hysteria.log" # 标准输出日志
error_log="/var/log/hysteria.error.log" # 错误输出日志

depend() { # 依赖项
  need net      # 需要网络服务
  after firewall # 在防火墙服务之后启动
}

start_pre() { # 启动前执行的命令
  checkpath -f \$output_log -m 0644 # 检查并创建日志文件，设置权限
  checkpath -f \$error_log -m 0644 # 检查并创建错误日志文件，设置权限
}

start() { # 启动服务函数
  ebegin "Starting \$name" # 开始启动服务的提示
  start-stop-daemon --start --quiet --background \\
    --make-pidfile --pidfile \$pidfile \\
    --stdout \$output_log --stderr \$error_log \\
    --exec \$command -- \$command_args # 启动进程
  eend \$? # 结束启动服务的提示，并显示结果
}

stop() { # 停止服务函数
    ebegin "Stopping \$name" # 开始停止服务的提示
    start-stop-daemon --stop --quiet --pidfile \$pidfile # 停止进程
    eend \$? # 结束停止服务的提示，并显示结果
}
# restart 命令由OpenRC通过调用stop然后start来处理
EOF
chmod +x /etc/init.d/hysteria # 赋予服务文件执行权限
echo -e "${GREEN}OpenRC 服务文件创建成功。${NC}" >&2

# --- 启用并启动服务 ---
echo -e "${YELLOW}正在启用并启动 Hysteria 服务...${NC}" >&2
rc-update add hysteria default >/dev/null # 将服务添加到默认运行级别
service hysteria stop >/dev/null 2>&1 # 尝试停止任何可能已在运行的实例
if ! service hysteria start; then # 启动服务并检查是否成功
    echo -e "${RED}Hysteria 服务启动失败。请检查以下日志获取错误信息:${NC}" >&2
    echo "  输出日志: tail -n 20 /var/log/hysteria.log" >&2
    echo "  错误日志: tail -n 20 /var/log/hysteria.error.log" >&2
    echo "  配置文件: cat /etc/hysteria/config.yaml" >&2
    exit 1
fi
echo -e "${GREEN}等待服务启动...${NC}" >&2; sleep 3 # 等待片刻让服务有时间启动和记录日志

# --- 显示结果 ---
if service hysteria status | grep -q "started"; then # 检查服务状态
    echo -e "${GREEN}Hysteria 服务已成功启动！${NC}"
else
    echo -e "${RED}Hysteria 服务状态异常。请检查日志:${NC}"
    echo "  输出日志: tail -n 20 /var/log/hysteria.log"
    echo "  错误日志: tail -n 20 /var/log/hysteria.error.log"
    echo "  配置文件: cat /etc/hysteria/config.yaml"
fi

SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${LINK_ADDRESS}:${PORT}/?sni=${LINK_SNI}&alpn=h3&insecure=${LINK_INSECURE}#Hysteria-${SNI}" # 生成订阅链接

echo "" # 输出空行，用于格式化
echo "------------------------------------------------------------------------"
echo -e "${GREEN}Hysteria 2 安装和配置完成！${NC}"
echo "------------------------------------------------------------------------"
echo "服务器地址 (用于客户端配置): $LINK_ADDRESS"
echo "端口: $PORT"
echo "密码: $PASSWORD"
echo "SNI / 伪装域名: $LINK_SNI"
echo "伪装目标站点: $MASQUERADE_URL"
echo "TLS 模式: $TLS_TYPE (1:Custom, 2:ACME-HTTP)"
if [ "$TLS_TYPE" -eq 1 ]; then
    echo "证书路径: $CERT_PATH; 私钥路径: $KEY_PATH" # 如果是自定义证书模式，显示证书路径
elif [ "$TLS_TYPE" -eq 2 ]; then
    echo "ACME 邮箱: $ACME_EMAIL" # 如果是ACME模式，显示使用的邮箱
fi
echo "客户端 insecure (0=false, 1=true): $LINK_INSECURE"
echo "------------------------------------------------------------------------"
echo -e "${YELLOW}订阅链接 (Hysteria V2):${NC}"
echo "$SUBSCRIPTION_LINK" # 输出订阅链接
echo "------------------------------------------------------------------------"

# 可选：显示二维码
if command -v qrencode &> /dev/null; then # 检查qrencode命令是否存在
    echo -e "${YELLOW}订阅链接二维码:${NC}"
    qrencode -t ANSIUTF8 "$SUBSCRIPTION_LINK" # 生成并显示二维码
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
