#!/bin/bash
set -euo pipefail

# 安装依赖
apk add --no-cache --update wget curl openssl openrc

# 生成随机密码（简化版）
generate_random_password() {
  dd if=/dev/urandom bs=18 count=1 status=none | base64 | tr -d '\n'
}

GENPASS="$(generate_random_password)"

# 生成配置文件（简化注释）
echo_hysteria_config_yaml() {
  cat << EOF
listen: :40443

# 有域名且使用ACME证书的配置示例
#acme:
#  domains: [your.domain.com]
#  email: admin@example.com

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $GENPASS

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF
}

# 简化服务文件
echo_hysteria_autoStart() {
  cat << EOF
#!/sbin/openrc-run

name="hysteria"
description="Hysteria VPN Service"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"

pidfile="/var/run/\${name}.pid"

depend() {
  need net
}
EOF
}

# 下载最新版（添加重试逻辑）
for i in {1..3}; do
  wget --show-progress -qO /usr/local/bin/hysteria \
    "https://download.hysteria.network/app/latest/hysteria-linux-amd64" && break
  sleep 3
done || {
  echo "错误：文件下载失败！" >&2
  exit 1
}
chmod +x /usr/local/bin/hysteria

# 创建配置目录
mkdir -p /etc/hysteria

# 生成证书（简化参数）
openssl req -x509 -nodes \
  -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout /etc/hysteria/server.key \
  -out /etc/hysteria/server.crt \
  -subj "/CN=bing.com" \
  -days 36500 || {
  echo "错误：证书生成失败！" >&2
  exit 1
}

# 写入配置文件
echo_hysteria_config_yaml > /etc/hysteria/config.yaml

# 配置服务
echo_hysteria_autoStart > /etc/init.d/hysteria
chmod 755 /etc/init.d/hysteria

# 启用服务
rc-update add hysteria
service hysteria start

# 输出安装信息
cat << EOF
------------------------------------------------------------------------
hysteria2 安装完成
端口: 40443
密码: $GENPASS
SNI: bing.com

配置文件: /etc/hysteria/config.yaml
服务状态: service hysteria status
重启服务: service hysteria restart
------------------------------------------------------------------------
EOF
