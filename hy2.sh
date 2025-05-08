#!/bin/bash
set -euo pipefail

# 安装依赖
apk add --no-cache --update wget curl openssl openrc

# 生成符合 RFC 4648 标准的 Base64 密码（24字符）
generate_random_password() {
  dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '\n' | tr +/ -_
}

GENPASS="$(generate_random_password)"

# 生成配置文件
echo_hysteria_config_yaml() {
  cat << EOF
listen: :40443

# 有域名且使用ACME证书的配置示例
#acme:
#  domains:
#    - your.domain.com
#  email: admin@example.com

# 自签名证书配置
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $GENPASS

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/  # 建议替换为自己的伪装站点
    rewriteHost: true
EOF
}

# 生成OpenRC服务文件（添加资源限制和日志配置）
echo_hysteria_autoStart() {
  cat << EOF
#!/sbin/openrc-run

name="hysteria"
description="Hysteria VPN Service"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_user="root:root"

pidfile="/var/run/\${name}.pid"
respawn_max=5
respawn_delay=10

depend() {
  need net
  use dns
}

start_pre() {
  checkpath -d -m 0755 /var/log/hysteria
}

logger -t "hysteria[\\\${RC_SVCNAME}]" -p local0.info
EOF
}

# 下载官方二进制文件（指定明确版本以提高稳定性）
HYSTERIA_VERSION="v2.6.1"
HYSTERIA_URL="https://github.com/apernet/hysteria/releases/download/${HYSTERIA_VERSION}/hysteria-linux-amd64"
wget --show-progress -qO /usr/local/bin/hysteria "$HYSTERIA_URL" || {
  echo "错误：文件下载失败！" >&2
  exit 1
}
chmod +x /usr/local/bin/hysteria

# 创建配置目录
mkdir -p /etc/hysteria

# 生成ECDSA证书（P-256曲线，有效期100年）
openssl req -x509 -nodes \
  -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=www.bing.com" \
  -days 36500 || {
  echo "错误：证书生成失败！" >&2
  exit 1
}

# 写入配置文件
echo_hysteria_config_yaml > /etc/hysteria/config.yaml

# 配置服务管理
echo_hysteria_autoStart > /etc/init.d/hysteria
chmod 755 /etc/init.d/hysteria

# 启用并启动服务
rc-update add hysteria default >/dev/null 2>&1
if ! service hysteria start; then
  echo "错误：服务启动失败！检查配置后重试" >&2
  exit 1
fi

# 验证服务状态
sleep 2
service hysteria status || {
  echo "警告：服务似乎未正常运行，检查日志：journalctl -u hysteria" >&2
}

# 显示安装结果
cat << EOF

███████╗████████╗███████╗██████╗ 
╚══███╔╝╚══██╔══╝██╔════╝██╔══██╗
  ███╔╝    ██║   █████╗  ██████╔╝
 ███╔╝     ██║   ██╔══╝  ██╔══██╗
███████╗   ██║   ███████╗██║  ██║
╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝

✅ 安装完成！配置文件路径：/etc/hysteria/config.yaml

▸ 服务器端口：40443/udp
▸ 认证密码：${GENPASS}
▸ TLS SNI：www.bing.com
▸ 传输类型：QUIC（伪装为HTTPS流量）

📌 客户端配置示例（hy3）：
{
  "server": "your_ip:40443",
  "auth": "[密码]",
  "tls": {
    "sni": "www.bing.com",
    "insecure": true
  },
  // ...其他客户端参数
}

🛠 管理命令：
service hysteria status  # 查看状态
service hysteria restart # 重启服务
journalctl -u hysteria   # 查看日志

EOF
