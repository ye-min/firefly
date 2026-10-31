# macOS 上的 Happ 配置指南

本文说明如何使用 Happ 连接本项目 `install.sh` 部署的 VLESS + REALITY + XTLS Vision 服务，并通过 Xray TUN 接管 macOS 流量。

本文基于 2026-10-30 实际排障及连接成功的配置整理，不代表所有客户端、服务端版本均已验证。

## 1. 已验证的环境

| 项目 | 版本或设置 |
| --- | --- |
| 客户端 | Happ 4.6.1，macOS Apple Silicon |
| 客户端内核 | Xray 26.10.21 |
| 服务端内核 | Xray 26.6.27，Linux amd64 |
| 节点协议 | VLESS + TCP + REALITY + XTLS Vision |
| 流量接管 | Xray TUN |
| 服务端出口 | 全流量 WARP；UDP 探测失败时阻断 UDP |
| DNS | Happ 路由配置中的 Cloudflare DoH |

服务端 26.6.27 是此次测试时的版本，并非要求新部署长期固定这个旧版本。其他版本组合需要单独验证。

## 2. 安装 Happ

从 [Happ 官方网站](https://happ.info/)或[官方桌面仓库](https://github.com/Happ-proxy/happ-desktop)下载安装程序。

macOS 使用 [Happ.macOS.universal.dmg](https://github.com/Happ-proxy/happ-desktop/releases/latest/download/Happ.macOS.universal.dmg)，支持 Apple Silicon 和 Intel。本文实际验证的是 Apple Silicon；以下界面路径对应 4.6.1 的 DMG 桌面版本。

打开 DMG，按安装窗口提示将 Happ 放入“应用程序”，启动后按提示完成所需网络组件授权。不要同时运行 SFM 或其他接管网络的 VPN 客户端。

## 3. 导入节点

1. 复制本次服务器安装完成时输出的 macOS `vless://` 分享链接。
2. 在 Happ 的节点添加入口使用从剪贴板导入功能。
3. 选中导入的节点，例如 `Reality-macos`。

不要将 `config_macos_global.json` 等 sing-box 配置文件作为本指南的输入。节点链接只携带连接参数，后面仍需配置 Happ 的流量接管和 DNS。

检查导入结果，不要重新生成密钥：

| 字段 | 设置 |
| --- | --- |
| Protocol | VLESS |
| Server / Port | 本次安装输出的服务器地址和端口 |
| Transport | TCP；部分界面称为 RAW |
| Security | REALITY |
| Flow | `xtls-rprx-vision` |
| Fingerprint | `chrome` |
| UUID、SNI、Public Key、Short ID | 保持本次分享链接导入的值 |

服务器重新安装后可能生成新的 UUID、密钥或 Short ID，应重新导入新链接。分享链接包含节点访问凭据，不要公开提交到仓库或粘贴到公开问题报告。

## 4. 固定使用 Xray TUN

修改设置前先断开 Happ。

在 **Transport Mode** 中选择 **TUN → Xray TUN**。

这里的 Proxy/TUN 是接管设备流量的方式，与节点里的 TCP 传输协议不是同一项。本文采用全设备接管，不同时开启系统代理。

在 **Settings → Advanced settings** 中设置：

| 选项 | 值 |
| --- | --- |
| TUN | On |
| Set system proxy | Off |
| Use local DNS | Off |
| Use DNS from JSON | Off |
| Enable sniffing | On，保持此次验证时的设置 |
| TUN DNS Address | `1.1.1.1` |

在 Settings 主页面保持：

| 选项 | 值 |
| --- | --- |
| Enable fragmentation | Off |
| Enable mux | Off |
| Preferred IP Type | IPv4 |
| Allow connection from LAN | Off |

仅填写 TUN DNS Address 并不等于已经配置 DoH，必须继续完成下一节。

## 5. 创建并启用 DoH 路由配置

### 5.1 创建配置

按以下路径操作：

1. 打开 **Settings → Routing rules**。
2. 点击右上角 **`…`**。
3. 选择 **Add Routing Profile**。
4. 在 “Which subscription should this profile be added to?” 中选择 **Server List**。如果节点在其他订阅中，应选择实际所属订阅。
5. 给配置起一个容易辨认的名称，例如 `Global-DoH`。此次操作中的名称为 `remote-us-5`，名称不影响功能。

新配置页面会显示 geoip、geosite 的下载状态。等待下载成功；如显示失败，不要把尚未完成加载的配置当作已生效。

### 5.2 DNS 设置

在该路由配置页面确认下列值。若新建配置已经采用这些默认值，无需重复修改。

| 区域 | 字段 | 值 |
| --- | --- | --- |
| Remote DNS | Remote DNS type | `DoH` |
| Remote DNS | URL | `https://cloudflare-dns.com/dns-query` |
| Remote DNS | IP | `1.1.1.1` |
| Domestic DNS | Domestic DNS type | `DoH` |
| Domestic DNS | URL | `https://dns.google/dns-query` |
| Domestic DNS | IP | `8.8.8.8` |
| Domain settings | Enable fake DNS | Off |
| Domain settings | Domain strategy | `IPIfNonMatch` |

此处保留 Domestic DNS 默认配置，但本文不添加国内网站直连规则。不要把“Remote DNS IP”或“TUN DNS Address”单独改成另一个公共 DNS 地址，认为这就完成了 DoH 配置。

### 5.3 全局代理规则

进入当前配置的 **Edit rules**：

| 选项 | 值 |
| --- | --- |
| Global proxy | On |
| Rule order | `Block → Direct → Proxy` |

**Direct** 中保留以下本地用途地址：

```text
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
169.254.0.0/16
224.0.0.0/4
255.255.255.255
```

这些条目包括私有网段、链路本地地址、组播和广播，不包含普通公网网站或 `1.1.1.1`。本指南不额外添加 Proxy、Direct 或 Block 规则，也不添加 `geoip:cn`、`geosite:cn` 等国内分流条目。

### 5.4 启用并重连

返回 **Routing rules** 列表，启用并选中刚创建的配置，使其用于当前节点所属的 Server List。

**创建或编辑配置不代表运行中的连接已应用它。必须断开 Happ，再重新连接。**

连接日志应确认路由启用，例如：

```text
[ROUTING]: Pre-flight check: routing enabled=1
```

如果仍为 `routing enabled=0`，先检查配置是否启用、是否绑定到了当前节点所属列表，以及是否已重连。

## 6. 验证连接

连接后访问 `https://openai.com` 或 `https://www.google.com`，确认域名可以解析、HTTPS 页面可以打开。此次故障在启用上述路由配置并重连后恢复。

如服务端选择了全流量 WARP，可在 Mac 终端执行：

```bash
curl --noproxy '*' --connect-timeout 5 --max-time 15 https://1.1.1.1/cdn-cgi/trace
```

这是不依赖域名解析的 HTTPS 测试。输出中的 `warp=on` 表示该请求通过 WARP 出口；它不单独证明系统 DNS 正常，也不证明所有应用均无直连。

Happ 日志中的 `Process started successfully` 和 `Tun mode enabled` 仅表示本地进程和 TUN 启动，不能代替实际访问验证。

## 7. 本次 DNS 故障的原因范围与修复

故障现象：

- 浏览器显示 `DNS_PROBE_STARTED` 或 `DNS_PROBE_FINISHED_NO_INTERNET`。
- 不依赖 DNS 的 HTTPS 测试成功，出口显示 `warp=on`。
- `dig @1.1.1.1 openai.com A` 和 `dig +tcp @1.1.1.1 openai.com A` 均超时。
- Happ 日志显示 `routing enabled=0`。

这些证据说明 HTTPS 转发可用，但测试时发往 `1.1.1.1:53` 的 DNS 查询路径不可用。由于 TCP DNS 也失败，不能把全部原因只归结为服务端阻断 UDP，更不能据此判断是 REALITY 握手失败。

本次有效修复是：**创建并启用带 Remote DoH 的全局路由配置，再重新连接 Happ。** 没有通过改换 DNS IP、切换 Proxy 模式或重装服务器解决。

DoH 修复的是 DNS 查询路径，不会恢复全流量 WARP 配置中被阻断的其他 UDP 应用。

## 8. 官方参考

- [Happ 官网](https://happ.info/)
- [桌面客户端下载](https://github.com/Happ-proxy/happ-desktop)
- [路由配置、DNS 字段与重连生效说明](https://github.com/HappDev/happ_su/blob/main/dev-docs/routing.md)
- [Happ 4.5.6：macOS TUN DNS 相关改进记录](https://github.com/Happ-proxy/happ-desktop/releases/tag/4.5.6)
