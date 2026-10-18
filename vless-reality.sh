#!/bin/sh
# =============================================================================
# Xray VLESS + Reality Alpine Linux 一键安装脚本
#  - 自动下载 Xray 核心（GitHub releases，30 秒超时）
#  - 自动生成 UUID / x25519 密钥对 / shortId
#  - 生成 /usr/local/etc/xray/config.json
#  - 注册 OpenRC 服务并启动，输出 vless 分享链接
# 用法: sh vless-reality.sh
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

c_red() { printf "${RED}%s${NC}\n" "$1" >&2; }
c_green() { printf "${GREEN}%s${NC}\n" "$1" >&2; }
c_yellow() { printf "${YELLOW}%s${NC}\n" "$1" >&2; }

printf "${YELLOW}Xray VLESS + Reality Alpine 一键安装${NC}\n"
printf "---------------------------------------\n"

# --- 依赖包安装 ---
c_yellow "正在安装必要的软件包..."
apk update >/dev/null 2>&1
for pkg in curl wget openssl unzip openrc; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
        printf "正在安装 %s...\n" "$pkg" >&2
        if ! apk add "$pkg" >/dev/null 2>&1; then
            c_red "错误: 安装 $pkg 失败，请手动安装后重试。"
            exit 1
        fi
    fi
done
c_green "依赖包安装成功。"

# --- 辅助函数 ---

# 生成 UUID（优先用内核随机源）
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        tr '[:upper:]' '[:lower:]' < /proc/sys/kernel/random/uuid | tr -d '\n'
    else
        openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
    fi
}

# 获取服务器公网 IP（优先 IPv4，IPv6 加中括号）
get_server_ip() {
    local ip
    printf "正在检测服务器公网 IP 地址...\n" >&2
    ip=$(curl -s -m 8 -4 https://api.ipify.org 2>/dev/null \
        || curl -s -m 8 -4 https://ip.sb 2>/dev/null \
        || curl -s -m 8 -4 https://checkip.amazonaws.com 2>/dev/null)
    if [ -n "$ip" ]; then
        c_green "检测到 IPv4 地址: $ip"
        printf "%s" "$ip"
        return 0
    fi
    printf "未检测到 IPv4，尝试 IPv6...\n" >&2
    ip=$(curl -s -m 8 -6 https://api64.ipify.org 2>/dev/null \
        || curl -s -m 8 -6 https://ip.sb 2>/dev/null)
    if [ -n "$ip" ]; then
        c_green "检测到 IPv6 地址: $ip"
        printf "[%s]" "$ip"
        return 0
    fi
    c_red "错误: 无法获取服务器公网 IP，请检查网络连接。"
    exit 1
}

# --- 用户输入 ---
DEFAULT_PORT="443"
DEFAULT_SNI="iosapps.itunes.apple.com"

printf "\n" >&2
read -p "请输入 Reality 监听端口 (默认 $DEFAULT_PORT): " PORT
PORT=${PORT:-$DEFAULT_PORT}

read -p "请输入 Reality 伪装目标域名/SNI (默认 $DEFAULT_SNI): " REALITY_SNI
REALITY_SNI=${REALITY_SNI:-$DEFAULT_SNI}

read -p "请输入 UUID (回车则随机生成): " UUID
if [ -z "$UUID" ]; then
    UUID=$(gen_uuid)
    printf "使用随机 UUID: %s\n" "$UUID" >&2
fi

# 端口占用提醒（尽力而为）
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ":$PORT "; then
    c_yellow "警告: 端口 $PORT 似乎已被占用，Xray 可能启动失败，可换端口重跑脚本。"
fi

SERVER_IP=$(get_server_ip)

# --- Xray 二进制下载 ---
XRAY_BIN="/usr/local/bin/xray"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l|armv6l) XRAY_ARCH="arm32-v7a" ;;
    *) c_red "不支持的系统架构: $ARCH"; exit 1 ;;
esac

# 若旧版本正在运行，先停止，避免覆盖执行中的二进制报 "Text file busy"
if [ -f "$XRAY_BIN" ]; then
    printf "检测到已安装旧版本，先停止服务以便替换二进制文件...\n" >&2
    service xray stop >/dev/null 2>&1
    sleep 1
fi

c_yellow "正在下载 Xray 核心..."
TMP_ZIP="/tmp/xray.zip"
if ! wget -T 30 -t 2 -qO "$TMP_ZIP" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"; then
    c_red "下载 Xray 失败，请检查网络后重试。"
    exit 1
fi
if ! unzip -o -q "$TMP_ZIP" xray -d /usr/local/bin/; then
    c_red "解压 Xray 失败。"
    exit 1
fi
chmod +x "$XRAY_BIN"
rm -f "$TMP_ZIP"
c_green "Xray 下载完成: $($XRAY_BIN version 2>/dev/null | head -1)"

# --- 生成 Reality 密钥与 shortId ---
c_yellow "正在生成 Reality 密钥对..."
KEY_OUT=$($XRAY_BIN x25519 2>/dev/null)
# 兼容新旧两种输出格式：
#   新版: "PrivateKey: xxx" / "Password (PublicKey): yyy"
#   旧版: "Private key: xxx" / "Public key: yyy"
PRIV_KEY=$(printf "%s" "$KEY_OUT" | awk -F': ' '/[Pp]rivate/{print $2}' | awk '{print $1}')
PUB_KEY=$(printf "%s" "$KEY_OUT" | awk -F': ' '/[Pp]ublic/{print $2}' | awk '{print $1}')
if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
    c_red "密钥生成失败，请检查 xray 二进制是否正常工作。"
    exit 1
fi
SHORT_ID=$(openssl rand -hex 8)
c_green "密钥对生成成功。"

# --- 生成 Xray 配置文件 ---
c_yellow "正在生成配置文件 /usr/local/etc/xray/config.json..."
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_SNI:443",
          "xver": 0,
          "serverNames": [
            "$REALITY_SNI"
          ],
          "privateKey": "$PRIV_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF
c_green "配置文件生成完毕。"

# --- 创建 OpenRC 服务 ---
c_yellow "正在创建 OpenRC 服务 /etc/init.d/xray..."
cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray VLESS+Reality service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
pidfile="/run/${name}.pid"
command_background="yes"
output_log="/var/log/xray/access.log"
error_log="/var/log/xray/error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d /var/log/xray
}
EOF
chmod +x /etc/init.d/xray
c_green "OpenRC 服务创建成功。"

# --- 启用并启动服务 ---
c_yellow "正在启用并启动 Xray 服务..."
rc-update add xray default >/dev/null 2>&1
if ! service xray start; then
    c_red "Xray 服务启动失败，请检查配置文件: cat /usr/local/etc/xray/config.json"
    exit 1
fi
sleep 2
if service xray status 2>/dev/null | grep -q "started"; then
    c_green "Xray 服务已成功启动！"
else
    c_red "Xray 服务状态异常，请检查日志: tail -n 20 /var/log/xray/error.log"
fi

# --- 生成分享链接 ---
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUB_KEY}&sid=${SHORT_ID}#Reality-${REALITY_SNI}"
printf "%s\n" "$VLESS_LINK" > /root/vless_reality_link.txt 2>/dev/null

printf "\n"
printf "------------------------------------------------------------------------\n"
printf "${GREEN}VLESS + Reality 安装完成！${NC}\n"
printf "------------------------------------------------------------------------\n"
printf "服务器地址: %s\n" "$SERVER_IP"
printf "端口: %s\n" "$PORT"
printf "UUID: %s\n" "$UUID"
printf "SNI/伪装目标: %s\n" "$REALITY_SNI"
printf "PublicKey (pbk): %s\n" "$PUB_KEY"
printf "ShortId (sid): %s\n" "$SHORT_ID"
printf "Flow: xtls-rprx-vision / 指纹: chrome\n"
printf "------------------------------------------------------------------------\n"
printf "${YELLOW}分享链接 (已保存到 /root/vless_reality_link.txt):${NC}\n"
printf "%s\n" "$VLESS_LINK"
printf "------------------------------------------------------------------------\n"
if command -v qrencode >/dev/null 2>&1; then
    printf "${YELLOW}分享链接二维码:${NC}\n"
    qrencode -t ANSIUTF8 "$VLESS_LINK"
else
    printf "${YELLOW}提示: 安装 qrencode (apk add qrencode) 后可显示二维码。${NC}\n"
fi
printf "------------------------------------------------------------------------\n"
printf "管理命令:\n"
printf "  service xray start    - 启动服务\n"
printf "  service xray stop     - 停止服务\n"
printf "  service xray restart  - 重启服务\n"
printf "  service xray status   - 查看状态\n"
printf "  cat /usr/local/etc/xray/config.json - 查看配置文件\n"
printf "一键卸载:\n"
printf "  service xray stop; rc-update del xray; rm /etc/init.d/xray; rm /usr/local/bin/xray; rm -rf /usr/local/etc/xray\n"
printf "------------------------------------------------------------------------\n"
