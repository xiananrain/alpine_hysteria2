#!/bin/bash

# 输出颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

echo -e "${YELLOW}Hysteria 2 Alpine Linux 安装脚本 (带崩溃重启功能)${NC}"
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
        echo "[$ipv6_ip]"
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
RESTART_DELAY_SECONDS=5 # 崩溃后重启延迟时间（秒）

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
        read -p "请输入证书 (.crt) 文件绝对路径 (回车则生成自签名证书): " USER_CERT_PATH
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
        read -p "请输入用于 ACME 证书申请的邮箱 (回车默认 $DEFAULT_ACME_EMAIL): " INPUT_ACME_EMAIL
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
WATCHDOG_SCRIPT_PATH="/usr/local/bin/hysteria_watchdog.sh" # Watchdog脚本路径

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
CONFIG_FILE_PATH="/etc/hysteria/config.yaml"
echo -e "${YELLOW}正在生成配置文件 $CONFIG_FILE_PATH...${NC}" >&2
cat > "$CONFIG_FILE_PATH" << EOF
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
        cat >> "$CONFIG_FILE_PATH" << EOF
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
        cat >> "$CONFIG_FILE_PATH" << EOF
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

# --- 创建 Watchdog 脚本 ---
WATCHDOG_LOG_FILE="/var/log/hysteria_watchdog.log"
echo -e "${YELLOW}正在创建 Hysteria Watchdog 脚本 $WATCHDOG_SCRIPT_PATH...${NC}" >&2
cat > "$WATCHDOG_SCRIPT_PATH" << EOF
#!/bin/bash
HYSTERIA_EXEC="$HYSTERIA_BIN"
CONFIG="$CONFIG_FILE_PATH"
RESTART_DELAY=${RESTART_DELAY_SECONDS}
LOG_FILE="$WATCHDOG_LOG_FILE"
HYSTERIA_PID_FILE="/var/run/hysteria_child.pid" # 用于存储实际Hysteria进程的PID

log_msg() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - \$1" >> "\$LOG_FILE"
}

# 信号处理函数，用于优雅地停止Hysteria子进程
graceful_shutdown() {
    log_msg "Watchdog received stop signal. Stopping Hysteria process..."
    if [ -f "\$HYSTERIA_PID_FILE" ]; then
        CHILD_PID=\$(cat "\$HYSTERIA_PID_FILE")
        if kill -0 "\$CHILD_PID" 2>/dev/null; then
            log_msg "Sending SIGTERM to Hysteria PID \$CHILD_PID."
            kill -TERM "\$CHILD_PID"
            # 等待一段时间让Hysteria进程自行退出
            for _ in $(seq 1 5); do # 最多等待5秒
                if ! kill -0 "\$CHILD_PID" 2>/dev/null; then
                    log_msg "Hysteria process \$CHILD_PID terminated gracefully."
                    rm -f "\$HYSTERIA_PID_FILE"
                    break
                fi
                sleep 1
            done
            # 如果仍在运行，强制终止
            if kill -0 "\$CHILD_PID" 2>/dev/null; then
                log_msg "Hysteria process \$CHILD_PID did not terminate, sending SIGKILL."
                kill -KILL "\$CHILD_PID"
            fi
        fi
        rm -f "\$HYSTERIA_PID_FILE"
    fi
    log_msg "Watchdog exiting."
    exit 0
}

# 捕获终止信号
trap 'graceful_shutdown' SIGTERM SIGINT SIGQUIT

log_msg "Watchdog started. Monitoring Hysteria."
checkpath -f \$LOG_FILE -m 0644 # 确保日志文件存在且权限正确

while true; do
    log_msg "Starting Hysteria: \$HYSTERIA_EXEC server --config \$CONFIG"
    # Hysteria的stdout和stderr将由OpenRC服务配置重定向
    \$HYSTERIA_EXEC server --config "\$CONFIG" &
    HY_PID=\$!
    echo "\$HY_PID" > "\$HYSTERIA_PID_FILE"
    log_msg "Hysteria started with PID \$HY_PID."

    wait "\$HY_PID" # 等待Hysteria进程退出
    EXIT_CODE=\$?
    rm -f "\$HYSTERIA_PID_FILE" # Hysteria已退出，删除其PID文件

    # 如果是由于trap信号导致的退出，graceful_shutdown会处理并退出watchdog
    # 如果是Hysteria自行崩溃或退出，则记录并重启
    log_msg "Hysteria process (PID \$HY_PID) exited with code \$EXIT_CODE."
    log_msg "Restarting Hysteria in \$RESTART_DELAY seconds..."
    sleep "\$RESTART_DELAY"
done
EOF
chmod +x "$WATCHDOG_SCRIPT_PATH"
echo -e "${GREEN}Hysteria Watchdog 脚本创建成功。${NC}" >&2

# --- 创建 OpenRC 服务文件 ---
echo -e "${YELLOW}正在创建 OpenRC 服务文件 /etc/init.d/hysteria...${NC}" >&2
cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run
name="hysteria"
description="Hysteria (managed by watchdog)"
# OpenRC 将管理 watchdog 脚本的 PID
pidfile="/var/run/\${name}.pid"
# Watchdog 脚本的路径
command="$WATCHDOG_SCRIPT_PATH"
# Watchdog 脚本不需要额外参数，它内部已经配置好了
command_args=""
command_background="yes" # Watchdog 脚本本身在后台运行

# Hysteria进程自身的输出和错误会被Watchdog捕获，
# 然后Watchdog的输出和错误会重定向到这里
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log"

depend() {
  need net
  after firewall
}

start_pre() {
  checkpath -f \$output_log -m 0644
  checkpath -f \$error_log -m 0644
  checkpath -f $WATCHDOG_LOG_FILE -m 0644 # Watchdog自己的日志
}

# start-stop-daemon将启动 $command (即watchdog脚本)
# watchdog脚本内部会启动实际的hysteria进程并监控它
# 当hysteria崩溃时，watchdog会重启它
# 当service hysteria stop时，start-stop-daemon会向watchdog脚本发送信号
# watchdog脚本的trap会捕获信号，然后尝试优雅停止hysteria子进程，然后watchdog自身退出

# 注意: start() 和 stop() 函数保持不变，因为它们现在管理的是 watchdog 进程
start() {
  ebegin "Starting \$name (via watchdog)"
  start-stop-daemon --start --quiet --background \\
    --make-pidfile --pidfile \$pidfile \\
    --stdout \$output_log --stderr \$error_log \\
    --exec \$command -- \$command_args
  eend \$?
}

stop() {
    ebegin "Stopping \$name (and its watchdog)"
    # 这会向 watchdog 进程发送 SIGTERM
    start-stop-daemon --stop --quiet --pidfile \$pidfile
    # Watchdog 脚本的 trap 会处理子进程的停止
    # 等待 watchdog 自身退出及其管理的 Hysteria 进程
    sleep 2 # 给 watchdog 一点时间处理
    if [ -f /var/run/hysteria_child.pid ]; then # 检查 Hysteria 子进程的 PID 文件
        CHILD_PID_TO_CLEAN=\$(cat /var/run/hysteria_child.pid)
        if kill -0 "\$CHILD_PID_TO_CLEAN" 2>/dev/null; then
            ewarn "Hysteria child process \$CHILD_PID_TO_CLEAN might still be running. Attempting to stop it."
            kill -TERM "\$CHILD_PID_TO_CLEAN"
            sleep 1
            kill -KILL "\$CHILD_PID_TO_CLEAN" 2>/dev/null
        fi
        rm -f /var/run/hysteria_child.pid
    fi
    eend \$?
}
EOF
chmod +x /etc/init.d/hysteria
echo -e "${GREEN}OpenRC 服务文件创建成功。${NC}" >&2

# --- 启用并启动服务 ---
echo -e "${YELLOW}正在启用并启动 Hysteria 服务...${NC}" >&2
rc-update add hysteria default >/dev/null
service hysteria stop >/dev/null 2>&1
if ! service hysteria start; then
    echo -e "${RED}Hysteria 服务启动失败。请检查以下日志获取错误信息:${NC}" >&2
    echo "  Hysteria 输出日志: tail -n 20 /var/log/hysteria.log" >&2
    echo "  Hysteria 错误日志: tail -n 20 /var/log/hysteria.error.log" >&2
    echo "  Watchdog 日志: tail -n 20 $WATCHDOG_LOG_FILE" >&2
    echo "  配置文件: cat $CONFIG_FILE_PATH" >&2
    exit 1
fi
echo -e "${GREEN}等待服务启动...${NC}" >&2; sleep 3

# --- 显示结果 ---
if service hysteria status | grep -q "started"; then
    echo -e "${GREEN}Hysteria 服务已成功启动 (由Watchdog管理)！${NC}"
else
    echo -e "${RED}Hysteria 服务状态异常。请检查日志:${NC}"
    echo "  Hysteria 输出日志: tail -n 20 /var/log/hysteria.log"
    echo "  Hysteria 错误日志: tail -n 20 /var/log/hysteria.error.log"
    echo "  Watchdog 日志: tail -n 20 $WATCHDOG_LOG_FILE"
    echo "  配置文件: cat $CONFIG_FILE_PATH"
fi

SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${LINK_ADDRESS}:${PORT}/?sni=${LINK_SNI}&alpn=h3&insecure=${LINK_INSECURE}#Hysteria-${SNI}"

echo ""
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
    echo "证书路径: $CERT_PATH; 私钥路径: $KEY_PATH"
elif [ "$TLS_TYPE" -eq 2 ]; then
    echo "ACME 邮箱: $ACME_EMAIL"
fi
echo "客户端 insecure (0=false, 1=true): $LINK_INSECURE"
echo "崩溃后重启延迟: ${RESTART_DELAY_SECONDS} 秒"
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
echo "管理命令："
echo "  service hysteria start   - 启动服务 (及Watchdog)"
echo "  service hysteria stop    - 停止服务 (及Watchdog)"
echo "  service hysteria restart - 重启服务 (及Watchdog)"
echo "  service hysteria status  - 查看服务状态 (Watchdog状态)"
echo "  cat $CONFIG_FILE_PATH - 查看Hysteria配置文件"
echo "  tail -f /var/log/hysteria.log - 查看Hysteria实时日志"
echo "  tail -f /var/log/hysteria.error.log - 查看Hysteria实时错误日志"
echo "  tail -f $WATCHDOG_LOG_FILE - 查看Watchdog实时日志"
echo "一键卸载命令："
echo "  service hysteria stop ; rc-update del hysteria ; rm /etc/init.d/hysteria ; rm -rf /etc/hysteria ; rm -f /var/run/hysteria.pid /var/run/hysteria_child.pid /var/log/hysteria* ; rm hy2.sh ; rm hysteria_watchdog.sh" 
echo "------------------------------------------------------------------------"
