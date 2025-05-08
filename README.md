# alpine-hysteria2

在 Alpine 中安装 hysteria2

## 一键食用

使用下面的命令一键安装并启动 hysteria2：

```bash
wget -O hy2.sh https://example.com/path/to/your/script/hy2.sh && sh hy2.sh

**注意**：重复执行脚本会覆盖之前的密码。

## 说明

### 安装与配置
- **脚本功能**：该脚本用于在 Alpine Linux 系统中一键安装并配置 hysteria2 服务。
- **配置文件**：`/etc/hysteria/config.yaml`  
  配置文件路径，包含 hysteria2 的所有配置信息。

### 服务设置
- **证书使用**：使用自签名证书进行 TLS 加密。
- **默认端口**：`40443`  
  Hysteria2 服务监听的默认 UDP 端口。
- **TLS 加密**：启用 TLS 加密，确保数据传输安全。
- **SNI (Server Name Indication)**：`bing.com`  
  用于 TLS 连接的服务器名称指示，伪装为访问 bing.com 的流量。

### 系统集成
- **自启动**：hysteria2 服务已配置为随系统自启动。  
  确保在系统重启后 hysteria2 服务能够自动运行。

### 管理命令
- **查看状态**：`service hysteria status`  
  使用此命令查看 hysteria2 服务的当前状态。
- **重启服务**：`service hysteria restart`  
  使用此命令重启 hysteria2 服务，适用于修改配置后的应用或故障恢复。

**注意**：  
请确保在运行脚本前，Alpine Linux 系统已配置好网络连接，并允许 UDP 端口 `40443` 的流量通过防火墙。此外，为了生产环境的安全性，建议使用有效的 CA 签名证书替代自签名证书。
