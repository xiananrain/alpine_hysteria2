# alpine-hysteria2

这是一个用于在 Alpine Linux 系统上自动安装和配置 Hysteria 2 的 Bash 脚本。

## 一键安装

使用下面的命令一键安装并启动 hysteria2：

```bash
wget -O hy2.sh https://raw.githubusercontent.com/1TIME1/alpine_hy2/main/hy2.sh && sh hy2.sh
```

## 功能特点

- 自动安装必要的软件包
- 生成随机密码（可选）
- 获取服务器 IP 地址（支持 IPv4 和 IPv6）
- 生成 Hysteria 2 配置文件
- 下载并配置 Hysteria 2 二进制文件
- 设置 Hysteria 2 服务随系统启动
- 生成 Hysteria 2 订阅链接
- 提供一键卸载命令

## 使用说明

运行脚本后，您将被提示输入以下信息：

- **端口**：Hysteria 2 监听的端口，默认为 34567。
- **密码**：用于身份验证的密码。如果不输入，将自动生成一个随机密码。
- **伪装域名（SNI）**：用于 TLS 握手的伪装域名，默认为 `www.bing.com`。

脚本将自动完成以下操作：

- 安装必要的软件包。
- 获取服务器 IP 地址（支持 IPv4 和 IPv6）。
- 生成自签名 TLS 证书。
- 创建 Hysteria 2 配置文件。
- 下载 Hysteria 2 二进制文件并赋予执行权限。
- 配置 OpenRC 自启动服务。
- 启动 Hysteria 2 服务。
- 生成 Hysteria 2 订阅链接。

安装完成后，脚本将输出安装摘要、订阅链接以及卸载命令。

### 订阅链接

脚本会生成一个 Hysteria 2 订阅链接，格式如下：

```
hysteria2://<password>@<server_ip>:<port>/?sni=<sni>&alpn=h3&insecure=1#hy2
```

- 您可以将此链接导入支持 Hysteria 2 的客户端进行使用。

## 配置选项

脚本使用以下默认值，您可以在运行时选择修改：

- **端口**：34567
- **密码**：随机生成（如果未输入）
- **伪装域名（SNI）**：`www.bing.com`

配置文件位于 `/etc/hysteria/config.yaml`，您可以手动编辑以进行高级配置。

## 卸载方法

脚本提供了一键卸载命令，用于停止服务、删除自启动配置、移除二进制文件、删除配置文件目录以及删除脚本本身。卸载命令将在安装完成后显示，您可以复制并在需要时执行。

默认卸载命令：
```bash
service hysteria stop ; rc-update del hysteria ; rm /etc/init.d/hysteria ; rm /usr/local/bin/hysteria ; rm -rf /etc/hysteria ; rm hy2.sh ; rm .wget-hsts
```

## 贡献指南

如果您有任何改进建议或发现了 bug，欢迎提交 Issue 或 Pull Request。

## 许可证

本脚本采用 [MIT 许可证](LICENSE) 开源。

---

**注意**：请确保您的服务器环境支持 Alpine Linux 及 OpenRC init 系统。本脚本未在其他 Linux 发行版上测试。
