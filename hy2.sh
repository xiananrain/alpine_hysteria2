#!/bin/bash

# --- 配置默认值 ---
DEFAULT_PORT="40443"
DEFAULT_PASSWORD=""
DEFAULT_DOMAIN="bing.com"
DEFAULT_REMARK_PREFIX="MyHysteria2" # 节点备注前缀

# --- 定义颜色输出 ---
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# --- 函数：生成随机密码 ---
generate_random_password() {
  if command -v openssl &> /dev/null; then
      openssl rand -base64 12
  else
      dd if=/dev/urandom bs=12 count=1 status=none 2>/dev/null | base64 | tr -d '\n'
  fi
}

# --- 函数：URL编码 (用于备注中的特殊字符) ---
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# --- 获取用户输入 ---
echo -e "${BLUE}欢迎使用 Hysteria 2 安装与配置脚本.${NC}"
echo -e "${YELLOW}如果直接回车，将使用括号中的默认值.${NC}\n"

read -p "$(echo -e ${YELLOW}"请输入 Hysteria 服务端口 (默认: ${DEFAULT_PORT}): "${NC})" USER_PORT
PORT="${USER_PORT:-$DEFAULT_PORT}"

if [ -z "$DEFAULT_PASSWORD" ]; then
    read -p "$(echo -e ${YELLOW}"请输入密码 (直接回车将生成随机密码): "${NC})" USER_PASSWORD
    if [ -z "$USER_PASSWORD" ]; then
        PASSWORD=$(generate_random_password)
        echo -e "${GREEN}未输入密码，已生成随机密码: ${BLUE}${PASSWORD}${NC}"
    else
        PASSWORD="$USER_PASSWORD"
    fi
else
    read -p "$(echo -e ${YELLOW}"请输入密码 (默认: ${DEFAULT_PASSWORD}): "${NC})" USER_PASSWORD
    PASSWORD="${USER_PASSWORD:-$DEFAULT_PASSWORD}"
fi

read -p "$(echo -e ${YELLOW}"请输入伪装域名 (例如 www.bing.com, 默认: ${DEFAULT_DOMAIN}): "${NC})" USER_DOMAIN
DOMAIN="${USER_DOMAIN:-$DEFAULT_DOMAIN}"

# --- 获取服务器公网 IP ---
echo -e "\n${BLUE}正在尝试自动获取服务器公网 IP 地址...${NC}"
SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me || wget -qO- -t1 -T2 api.ip.sb/ip || wget -qO- -t1 -T2 ifconfig.me/ip)

if [ -z "$SERVER_IP" ]; then
    echo -e "${YELLOW}自动获取公网 IP 失败。${NC}"
    read -p "$(echo -e ${YELLOW}"请输入你的服务器公网 IP 地址: "${NC})" MANUAL_IP
    if [ -z "$MANUAL_IP" ]; then
        echo -e "${RED}未提供服务器 IP 地址，无法生成分享链接。请手动配置客户端。${NC}"
        SERVER_IP="YOUR_SERVER_IP" # 占位符
    else
        SERVER_IP="$MANUAL_IP"
    fi
else
    echo -e "${GREEN}获取到服务器公网 IP: ${BLUE}${SERVER_IP}${NC}"
fi


# --- 显示最终配置信息 ---
echo -e "\n-------------------------------------"
echo -e "${GREEN}配置确认:${NC}"
echo -e "服务器 IP : ${BLUE}${SERVER_IP}${NC}"
echo -e "服务端口  : ${BLUE}${PORT}${NC}"
echo -e "密码      : ${BLUE}${PASSWORD}${NC}"
echo -e "伪装域名  : ${BLUE}${DOMAIN}${NC} (此域名也将用于自签名证书的CN)"
echo -e "-------------------------------------\n"

read -p "$(echo -e ${YELLOW}"确认以上配置并开始安装吗? (y/N): "${NC})" confirmation
if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
    echo -e "${RED}操作已取消。${NC}"
    exit 1
fi

echo -e "\n${GREEN}开始安装和配置 Hysteria...${NC}"

# --- 依赖安装 ---
echo -e "\n${BLUE}正在安装依赖 (wget, curl, git, openssh, openssl, openrc)...${NC}"
apk add wget curl git openssh openssl openrc
if [ $? -ne 0 ]; then
    echo -e "${RED}依赖安装失败，请检查网络或手动安装后再试。${NC}"
    exit 1
fi

# --- Hysteria 配置函数 ---
echo_hysteria_config_yaml() {
  cat << EOF
listen: :${PORT}
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: ${PASSWORD}
masquerade:
  type: proxy
  proxy:
    url: https://${DOMAIN}/
    rewriteHost: true
# 如果你需要带宽控制 (示例，默认不启用)
# upMbps: 100
# downMbps: 500
EOF
}

# --- Hysteria 自启动脚本函数 ---
echo_hysteria_autoStart(){
  cat << EOF
#!/sbin/openrc-run
name="hysteria"
description="Hysteria V2 Server"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${RC_SVCNAME}.pid"
command_background="yes"
depend() {
        need net
        after firewall
}
start_pre() {
    checkpath -d -m 0750 /var/run
    checkpath -f -m 0640 \${pidfile}
}
EOF
}

# --- 下载并安装 Hysteria ---
echo -e "\n${BLUE}正在下载 Hysteria 最新版本...${NC}"
HYSTERIA_LATEST_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/apernet/hysteria/releases/latest)
HYSTERIA_VERSION=$(basename "${HYSTERIA_LATEST_URL}")
HYSTERIA_DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-amd64"
echo "下载链接: $HYSTERIA_DOWNLOAD_URL"

wget -O /usr/local/bin/hysteria "${HYSTERIA_DOWNLOAD_URL}" --no-check-certificate
if [ $? -ne 0 ]; then
    echo -e "${RED}Hysteria 下载失败，请检查URL或网络。${NC}"
    exit 1
fi
chmod +x /usr/local/bin/hysteria

# --- 创建配置目录和证书 ---
echo -e "\n${BLUE}正在创建配置目录和生成自签名证书...${NC}"
mkdir -p /etc/hysteria/
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=${DOMAIN}" -days 36500
if [ $? -ne 0 ]; then
    echo -e "${RED}自签名证书生成失败。${NC}"
    exit 1
fi

# --- 写入配置文件 ---
echo -e "\n${BLUE}正在写入 Hysteria 配置文件...${NC}"
echo_hysteria_config_yaml > "/etc/hysteria/config.yaml"

# --- 写入并启用自启动服务 ---
echo -e "\n${BLUE}正在设置 Hysteria 开机自启动...${NC}"
echo_hysteria_autoStart > "/etc/init.d/hysteria"
chmod +x /etc/init.d/hysteria
rc-update add hysteria default
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}添加到开机自启可能失败了，请检查。可以尝试手动执行 rc-update add hysteria default ${NC}"
fi

# --- 启动 Hysteria 服务 ---
echo -e "\n${BLUE}正在启动 Hysteria 服务...${NC}"
service hysteria stop >/dev/null 2>&1
service hysteria start
sleep 2

# --- 检查服务状态 ---
if service hysteria status | grep -q "started"; then
    echo -e "${GREEN}Hysteria 服务已成功启动。${NC}"
else
    echo -e "${RED}Hysteria 服务启动失败，请检查日志：journalctl -u hysteria 或查看 /var/log/messages ${NC}"
    echo -e "${YELLOW}你也可以尝试手动运行: /usr/local/bin/hysteria server --config /etc/hysteria/config.yaml ${NC}"
fi

# --- 生成分享链接和订阅链接 ---
NODE_REMARK_RAW="${DEFAULT_REMARK_PREFIX}-${DOMAIN}" # 原始备注
NODE_REMARK_URLENCODED=$(urlencode "${NODE_REMARK_RAW}") # URL编码后的备注

# Hysteria 2 (hy2://) 格式
# hy2://AUTH@HOST:PORT?sni=SNI&insecure=1#REMARK
HY2_URI="hy2://${PASSWORD}@${SERVER_IP}:${PORT}?sni=${DOMAIN}&insecure=1#${NODE_REMARK_URLENCODED}"

# Base64 编码的订阅链接 (单个节点)
SUB_LINK=$(echo -n "${HY2_URI}" | base64 -w0)


# --- 显示最终信息 ---
echo -e "\n------------------------------------------------------------------------"
echo -e "${GREEN}Hysteria 2 安装与配置完成!${NC}"
echo -e "服务器 IP     : ${BLUE}${SERVER_IP}${NC}"
echo -e "服务端口      : ${BLUE}${PORT}${NC}"
echo -e "密码          : ${BLUE}${PASSWORD}${NC}"
echo -e "伪装域名(SNI) : ${BLUE}${DOMAIN}${NC}"
echo -e "TLS 证书类型  : ${BLUE}自签名 (server.crt, server.key)${NC}"
echo -e "配置文件路径  : ${BLUE}/etc/hysteria/config.yaml${NC}"
echo -e "------------------------------------------------------------------------"
echo -e "${YELLOW}客户端配置提示:${NC}"
echo -e "  - 服务器地址: ${SERVER_IP}"
echo -e "  - 服务器端口: ${PORT}"
echo -e "  - 认证密码  : ${PASSWORD}"
echo -e "  - TLS设置   : 开启, 允许不安全/跳过证书验证 (insecure: true)"
echo -e "  - SNI/Peer  : ${DOMAIN}"
echo -e "  - 备注      : ${NODE_REMARK_RAW}"
echo -e "------------------------------------------------------------------------"
echo -e "${GREEN}Hysteria 2 (hy2) 分享链接:${NC}"
echo -e "${BLUE}${HY2_URI}${NC}"
echo -e "\n${GREEN}V2RayNG / Nekobox 等客户端可用的 Base64 订阅链接 (复制全部内容):${NC}"
echo -e "${BLUE}${SUB_LINK}${NC}"
echo -e "------------------------------------------------------------------------"
echo -e "常用命令:"
echo -e "  查看状态: ${BLUE}service hysteria status${NC}"
echo -e "  启动服务: ${BLUE}service hysteria start${NC}"
echo -e "  停止服务: ${BLUE}service hysteria stop${NC}"
echo -e "  重启服务: ${BLUE}service hysteria restart${NC}"
echo -e "  查看日志: ${BLUE}tail -f /var/log/messages | grep hysteria${NC} (Alpine Linux)"
echo -e "------------------------------------------------------------------------"
echo -e "${GREEN}请享用！${NC}"
