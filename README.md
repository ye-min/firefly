# firefly

需要 root、正在运行的 systemd，以及公网 IPv4。仅支持全新安装；重装前请先运行 `uninstall.sh`。

## 客户端配置

- [macOS 上的 Happ 配置指南](docs/happ-macos.md)：节点导入、Xray TUN、全局代理与 DoH DNS 设置。

## 一键部署
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ye-min/firefly/master/install.sh)
```

```bash
curl -fsSL https://raw.githubusercontent.com/ye-min/firefly/master/install.sh -o install.sh
sudo bash install.sh
```

## install2.sh

`install2.sh` 是 `install.sh` 的改进版。协议仍是 VLESS + Reality + XTLS Vision，询问的配置项与当前 `install.sh` 相同，并且继续为每个系统同时生成全局代理与国内外分流两套配置。上一节的 `install.sh` 用法不变。卸载脚本仍是 `uninstall.sh`。

和 `install.sh` 相比，`install2.sh` 会：

- 从 `/dev/tty` 读取交互输入（`read -r`），避免把脚本后面的内容当成答案。
- 等用户确认配置之后才安装依赖，并且只安装必要软件包，不执行全系统升级。在确认前提示里选取消，不会改动系统软件包。若之后安装失败，请先自行更新系统再重试。
- 在 sing-box 客户端路由里加入私网直连（`ip_is_private`），避免 TUN 把局域网送进代理。
- 把 Xray 官方安装器固定到指定 commit 并校验 sha256；导入 Cloudflare WARP 公钥前先核对指纹。不固定、也不降级 Xray-core 本身。
- 不再把服务端私钥打印到终端。客户端 JSON 校验失败会停止部署。

推荐先下载再执行，便于检查脚本内容：

```bash
curl -fsSL https://raw.githubusercontent.com/ye-min/firefly/master/install2.sh -o install2.sh
sudo bash install2.sh
```

如果使用一条命令，请用过程替换（不会占用标准输入）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ye-min/firefly/master/install2.sh)
```

**不要使用 `curl … | bash` 或 `wget -O- | bash`。** 脚本需要交互输入。管道会把后续脚本内容送给 `read`；`install2.sh` 已改为从 `/dev/tty` 读取，但没有终端的环境仍会失败，而且这种方式不便于在执行前审查脚本。

分流配置里的 geoip/geosite 规则集目前只有一个 jsDelivr 地址。若客户端下载失败，请手动更换配置中的 `url` 后再导入。

### sing-box 与当前 REALITY 服务端

`install2.sh` 仍会生成 `config_*_global.json` 和 `config_*_split.json`。Xray-core >= v26.9.8 的 REALITY 服务端会拒绝 sing-box 客户端：sing-box 会从 ClientHello 中去掉 X25519MLKEM768（见 [sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520)）。这些 JSON 目前连不上本脚本部署的服务端。脚本不会为此降级或固定旧版 Xray-core。

请改用基于 Xray-core 的客户端，导入脚本输出的 `vless://` 分享链接，例如：

- Happ（Android / iOS / Windows / macOS）。macOS 可参考 [Happ 配置指南](docs/happ-macos.md)
- v2rayN（Windows）
- v2rayNG（Android）

或使用 mihomo，并同时设置 `client-fingerprint: chrome` 与：

```yaml
reality-opts:
  support-x25519mlkem768: true
```

## 卸载

`install.sh` 与 `install2.sh` 共用同一个卸载脚本：

```bash
sudo bash uninstall.sh
```
