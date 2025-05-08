#!/bin/bash

# 安装必要的软件包，包括 libuuid 以支持 uuidgen
apk add wget curl git openssh openssl openrc libuuid

# 提供默认值
read -p "请输入端口（默认 34567）: " PORT
PORT=${PORT:-34567}

# 生成随机 UUID 作为密码
PASSWORD=$(uuidgen)
echo "生成的 UUID: $PASSWORD"

read -p "请输入伪装域名（默认 www.bing.com）: " SNI
SNI=${SNI:-www.bing.com}

# 获取服务器 IP 地址
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
  echo "无法获取服务器 IP 地址，请检查网络连接。"
  exit 1
fi

# 生成 Hysteria config.yaml 的函数
echo_hysteria_config_yaml() {
  cat << EOF
listen: :$PORT

# 有域名时使用 CA 证书（默认注释掉）
#acme:
#  domains:
#    - test.heybro.bid # 你的域名，需要先解析到服务器 IP
#  email: xxx@gmail.com

# 使用自签名证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$SNI/
    rewriteHost: true
EOF
}

# 生成 OpenRC 自启动脚本的函数
echo_hysteria_autoStart() {
  cat << EOF
#!/sbin/openrc-run

name="hysteria"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"

pidfile="/var/run/\${name}.pid"

command_background="yes"

depend() {
  need networking
}
EOF
}

# 下载 Hysteria 二进制文件并赋予执行权限
wget -O /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64 --no-check-certificate
chmod +x /usr/local/bin/hysteria

# 创建 Hysteria 配置文件目录
mkdir -p /etc/hysteria/

# 生成自签名 TLS 证书
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj "/CN=$SNI" -days 36500

# 写入配置文件
echo_hysteria_config_yaml > "/etc/hysteria/config.yaml"

# 写入并配置自启动脚本
echo_hysteria_autoStart > "/etc/init.d/hysteria"
chmod +x /etc/init.d/hysteria
rc-update add hysteria

# 启动 Hysteria 服务
service hysteria start

# 生成 Hysteria 2 订阅链接
SUBSCRIPTION_LINK="hysteria2://$PASSWORD@$SERVER_IP:$PORT/?sni=$SNI&alpn=h3&insecure=1#hy2"

# 输出安装摘要和卸载说明
echo "------------------------------------------------------------------------"
echo "hysteria2 已安装完成"
echo "端口：$PORT，密码（UUID）：$PASSWORD，伪装域名（SNI）：$SNI"
echo "配置文件：/etc/hysteria/config.yaml"
echo "已设置为随系统自动启动"
echo "查看状态：service hysteria status"
echo "重启服务：service hysteria restart"
echo "------------------------------------------------------------------------"
echo "一键复制粘贴到支持 Hysteria 2 的客户端的订阅链接："
echo "$SUBSCRIPTION_LINK"
echo "注意：如果您的 V2Ray 客户端不支持 Hysteria 2，请使用支持该协议的客户端。"
echo "------------------------------------------------------------------------"
echo "卸载 Hysteria 2 的命令："
echo "service hysteria stop"
echo "rc-update del hysteria"
echo "rm /etc/init.d/hysteria"
echo "rm /usr/local/bin/hysteria"
echo "rm -rf /etc/hysteria"
echo "------------------------------------------------------------------------"
echo "请享用。"
echo "------------------------------------------------------------------------"
