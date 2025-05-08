# alpine-hysteria2

这是一个用于在 Alpine Linux 系统上自动安装和配置 Hysteria 2 的 Bash 脚本。

## 一键安装

使用下面的命令一键安装并启动 Hysteria 2：

```bash
curl -fsSL https://raw.githubusercontent.com/1TIME1/alpine_hy2/main/hy2.sh -o hy2.sh && chmod +x hy2.sh && sh hy2.sh
```

## 功能特点

- 自动安装必要的软件包。
- 支持两种 TLS 验证方式：
  - 自定义证书（适用于已有证书或 NAT VPS 生成自签名证书）。
  - ACME HTTP 验证（需要域名指向本机 IP）。
- 生成随机密码（可选，使用 UUID v4 格式）。
- 获取服务器 IP 地址（支持 IPv4 和 IPv6，优先使用 IPv6）。
- 生成 Hysteria 2 配置文件。
- 下载并配置 Hysteria 2 二进制文件。
- 设置 Hysteria 2 服务随系统启动（使用 OpenRC）。
- 生成 Hysteria 2 订阅链接。
- 提供一键卸载命令。

## 使用说明

运行脚本后，您将被提示选择 TLS 验证方式并输入相关信息：

1. **TLS 验证方式**：
   - **1. 自定义证书**：适用于已有证书或 NAT VPS 生成自签名证书。
   - **2. ACME HTTP 验证**：需要域名指向本机 IP，且本机 80 端口可被 Hysteria 使用。

2. 根据选择的 TLS 验证方式，输入相应的信息：
   - **自定义证书**：
     - 证书 (.crt) 文件绝对路径（留空则生成自签名证书）。
     - 私钥 (.key) 文件绝对路径。
     - 用于自签名证书的伪装域名（如果选择生成自签名证书，默认 `www.bing.com`）。
   - **ACME HTTP 验证**：
     - 您的域名（例如：`example.com`）。
     - 用于 ACME 证书申请的邮箱（默认生成随机邮箱，如 `xxxxxxxx@gmail.com`）。

3. **端口**：Hysteria 2 监听的端口，默认为 `34567`。
4. **密码**：用于身份验证的密码。如果不输入，将自动生成一个随机 UUID。
5. **伪装访问的目标 URL**：用于伪装流量的目标 URL，默认为 `https://www.bing.com`。

脚本将自动完成以下操作：

- 安装必要的软件包。
- 获取服务器 IP 地址（支持 IPv4 和 IPv6，优先使用 IPv6）。
- 根据选择的 TLS 验证方式，生成或使用证书。
- 创建 Hysteria 2 配置文件（位于 `/etc/hysteria/config.yaml`）。
- 下载 Hysteria 2 二进制文件并赋予执行权限。
- 配置 OpenRC 自启动服务。
- 启动 Hysteria 2 服务。
- 生成 Hysteria 2 订阅链接。

安装完成后，脚本将输出安装摘要、订阅链接以及管理命令。

### 订阅链接

脚本会生成一个 Hysteria 2 订阅链接，格式如下：

```
hysteria2://<password>@<server_address>:<port>/?sni=<sni>&alpn=h3&insecure=<insecure>#Hysteria-<sni>
```

- `<server_address>`：服务器地址（IP 或域名）。
- `<port>`：Hysteria 2 监听的端口。
- `<password>`：身份验证密码。
- `<sni>`：TLS 握手时的 SNI（伪装域名）。
- `<insecure>`：是否允许不安全的 TLS 连接（`0` 或 `1`）。

您可以将此链接导入支持 Hysteria 2 的客户端进行使用。

**注意**：如果使用自定义证书（尤其是自签名证书），客户端通常需要设置 `insecure: true`。

## 配置选项

脚本使用以下默认值，您可以在运行时选择修改：

- **端口**：`34567`
- **密码**：随机生成的 UUID（如果未输入）
- **伪装访问的目标 URL**：`https://www.bing.com`
- **伪装域名（自签名证书）**：`www.bing.com`
- **ACME 邮箱**：随机生成的邮箱（如 `xxxxxxxx@gmail.com`，如果选择 ACME HTTP 验证）

配置文件位于 `/etc/hysteria/config.yaml`，您可以手动编辑以进行高级配置。

## 卸载方法

脚本提供了一键卸载命令，用于停止服务、删除自启动配置、移除二进制文件、删除配置文件目录以及删除脚本本身。卸载命令如下：

```bash
service hysteria stop ; rc-update del hysteria ; rm /etc/init.d/hysteria ; rm /usr/local/bin/hysteria ; rm -rf /etc/hysteria ; rm hy2.sh
```

安装完成后，脚本会显示此命令，您可以复制并在需要时执行。

## 贡献指南

如果您有任何改进建议或发现了 bug，欢迎提交 Issue 或 Pull Request。

## 许可证

本脚本采用 [MIT 许可证](LICENSE) 开源。

---

**注意**：请确保您的服务器环境支持 Alpine Linux 及 OpenRC init 系统。本脚本未在其他 Linux 发行版上测试。
