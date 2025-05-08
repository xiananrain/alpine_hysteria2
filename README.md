# alpine-hysteria2

在 Alpine 中安装 hysteria2

## 一键食用

使用下面的命令一键安装并启动 hysteria2：

```bash
wget -O hy2.sh https://raw.githubusercontent.com//1TIME1/alpine_hy2/main/hy2.sh && sh hy2.sh

> **警告**  
> 重复执行脚本将会覆盖之前设置的密码

## 功能特性

### 安装与配置
- **脚本功能**：在 Alpine Linux 系统上一键安装并配置 hysteria2 服务
- **配置文件**：`/etc/hysteria/config.yaml`  
  包含 hysteria2 的所有配置设置

### 服务设置
- **证书**：使用自签名证书进行 TLS 加密
- **默认端口**：`40443` (UDP)  
  Hysteria2 服务的默认监听端口
- **TLS 加密**：启用以确保数据传输安全
- **SNI**：`bing.com`  
  用于 TLS 连接的服务器名称指示，将流量伪装为访问 Bing

### 系统集成
- **自动启动**：服务已配置为随系统自动启动

## 管理命令
| 命令 | 说明 |
|------|------|
| `service hysteria status` | 检查服务状态 |
| `service hysteria restart` | 重启服务（应用配置更改或故障恢复） |

## 重要说明
1. 确保 Alpine Linux 已满足：
   - 正确的网络配置
   - 防火墙允许 UDP 端口 `40443`
2. 生产环境建议：
   - **强烈建议**：使用有效的 CA 签名证书替换自签名证书
