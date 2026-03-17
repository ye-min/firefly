#!/bin/bash

# =============================================================
# Xray 一键部署脚本 (增强版 v3)
# 协议: VLESS + Reality + XTLS Vision
# sing-box 配置语法: 1.11+ (新版)
#
# 新增功能:
#   1. 选择客户端系统类型 (iOS/macOS/Android/Windows/Linux)
#      → 不同系统 inbounds 结构不同
#   2. 选择 TLS 指纹（根据系统自动推荐）
#   3. 选择路由模式（全局 / 国内外分流）
#   4. 终端完整显示 sing-box JSON 配置 + 保存文件
#   5. 生成 VLESS 分享链接
# =============================================================

set -e

# ---- 颜色 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $1"; }

print_line()  { echo -e "${BLUE}=============================================${NC}"; }
print_dline() { echo -e "${BLUE}==============================================${NC}"; }

# =============================================================
# 检查 root 权限
# =============================================================
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# =============================================================
# 欢迎界面
# =============================================================
clear
echo ""
print_dline
echo -e "${BOLD}${MAGENTA}     Xray VLESS + Reality 一键部署 (v3)${NC}"
echo -e "${DIM}     sing-box 1.11+ 新版配置语法${NC}"
print_dline
echo ""
log_warn "以下信息将写入服务端配置，请准确填写"
echo ""

# =============================================================
# 交互式输入 — 基础参数
# =============================================================

# ---- UUID ----
while true; do
    read -p "$(echo -e ${CYAN}'请输入 UUID（直接回车自动生成）: '${NC})" INPUT_UUID
    if [[ -z "$INPUT_UUID" ]]; then
        INPUT_UUID=$(cat /proc/sys/kernel/random/uuid)
        log_info "已自动生成 UUID: ${INPUT_UUID}"
        break
    elif [[ "$INPUT_UUID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        break
    else
        log_error "UUID 格式不正确，请重新输入"
    fi
done

# ---- 端口 ----
while true; do
    read -p "$(echo -e ${CYAN}'请输入监听端口（直接回车使用默认 443）: '${NC})" INPUT_PORT
    INPUT_PORT=${INPUT_PORT:-443}
    if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        break
    else
        log_error "端口号必须在 1-65535 之间"
    fi
done

# ---- SNI ----
read -p "$(echo -e ${CYAN}'请输入 SNI 域名（直接回车使用默认 cdn.jsdelivr.net）: '${NC})" INPUT_SNI
INPUT_SNI=${INPUT_SNI:-cdn.jsdelivr.net}

# =============================================================
# 交互 — 客户端系统类型
# =============================================================
#
#  不同操作系统上 sing-box 的 inbounds 配置存在本质区别:
#
#  ┌──────────┬───────────────────────────────────────────────────────────┐
#  │ iOS      │ 纯 tun。系统 Network Extension 接管全部流量。            │
#  │          │ 不需要 mixed 入站，App 不在本地开代理端口。              │
#  ├──────────┼───────────────────────────────────────────────────────────┤
#  │ macOS    │ tun 为主。可选加 mixed 入站给终端/浏览器手动设代理用。   │
#  │          │ interface_name 通常为 utun0。                            │
#  ├──────────┼───────────────────────────────────────────────────────────┤
#  │ Android  │ 纯 tun。通过 VPN Service API 创建虚拟网卡，             │
#  │          │ 系统级接管所有 App 流量。                                │
#  ├──────────┼───────────────────────────────────────────────────────────┤
#  │ Windows  │ tun + mixed。TUN 全局接管 + mixed(HTTP/SOCKS5)入站       │
#  │          │ 给浏览器扩展(SwitchyOmega)等使用。需管理员权限。        │
#  ├──────────┼───────────────────────────────────────────────────────────┤
#  │ Linux    │ tun + mixed + tproxy。mixed 供终端 export proxy 用；     │
#  │          │ tproxy 端口供旁路由/网关做透明代理。                     │
#  └──────────┴───────────────────────────────────────────────────────────┘
#
echo ""
print_line
echo -e "${BOLD}  请选择客户端系统类型${NC}"
echo -e "${DIM}  (不同系统的 sing-box inbounds 配置有本质区别)${NC}"
print_line
echo ""
echo -e "  ${GREEN}1)${NC} iOS          ${YELLOW}← Stash / Shadowrocket / sing-box iOS${NC}"
echo -e "  ${GREEN}2)${NC} macOS        ${YELLOW}← sing-box macOS (SFI) / V2rayU${NC}"
echo -e "  ${GREEN}3)${NC} Android      ${YELLOW}← sing-box Android / NekoBox / v2rayNG${NC}"
echo -e "  ${GREEN}4)${NC} Windows      ${YELLOW}← sing-box Windows / v2rayN / NekoRay${NC}"
echo -e "  ${GREEN}5)${NC} Linux        ${YELLOW}← sing-box CLI / 旁路由网关${NC}"
echo ""

while true; do
    read -p "$(echo -e ${CYAN}'请输入选项 [1-5]（直接回车默认 iOS）: '${NC})" OS_CHOICE
    OS_CHOICE=${OS_CHOICE:-1}
    case "$OS_CHOICE" in
        1) CLIENT_OS="ios";     break ;;
        2) CLIENT_OS="macos";   break ;;
        3) CLIENT_OS="android"; break ;;
        4) CLIENT_OS="windows"; break ;;
        5) CLIENT_OS="linux";   break ;;
        *) log_error "无效选项，请输入 1-5" ;;
    esac
done
log_info "已选择客户端系统: ${CLIENT_OS}"

# =============================================================
# 交互 — TLS 指纹（根据系统推荐默认值）
# =============================================================
case "$CLIENT_OS" in
    ios)     DEFAULT_FP="safari";  DEFAULT_FP_NUM=3 ;;
    macos)   DEFAULT_FP="chrome";  DEFAULT_FP_NUM=1 ;;
    android) DEFAULT_FP="chrome";  DEFAULT_FP_NUM=1 ;;
    windows) DEFAULT_FP="chrome";  DEFAULT_FP_NUM=1 ;;
    linux)   DEFAULT_FP="firefox"; DEFAULT_FP_NUM=2 ;;
esac

echo ""
print_line
echo -e "${BOLD}  请选择 TLS 客户端指纹 (uTLS Fingerprint)${NC}"
echo -e "${DIM}  (建议与客户端系统匹配，已根据系统推荐默认值)${NC}"
print_line
echo ""
echo -e "  ${GREEN}1)${NC} chrome       $([ "$DEFAULT_FP" = "chrome"  ] && echo -e "${YELLOW}← 推荐${NC}" || echo "")"
echo -e "  ${GREEN}2)${NC} firefox      $([ "$DEFAULT_FP" = "firefox" ] && echo -e "${YELLOW}← 推荐${NC}" || echo "")"
echo -e "  ${GREEN}3)${NC} safari       $([ "$DEFAULT_FP" = "safari"  ] && echo -e "${YELLOW}← 推荐${NC}" || echo "")"
echo -e "  ${GREEN}4)${NC} edge"
echo -e "  ${GREEN}5)${NC} random       ${DIM}(随机指纹)${NC}"
echo ""

while true; do
    read -p "$(echo -e ${CYAN}"请输入选项 [1-5]（直接回车默认 ${DEFAULT_FP}）: "${NC})" FP_CHOICE
    FP_CHOICE=${FP_CHOICE:-$DEFAULT_FP_NUM}
    case "$FP_CHOICE" in
        1) CLIENT_FINGERPRINT="chrome";  break ;;
        2) CLIENT_FINGERPRINT="firefox"; break ;;
        3) CLIENT_FINGERPRINT="safari";  break ;;
        4) CLIENT_FINGERPRINT="edge";    break ;;
        5) CLIENT_FINGERPRINT="random";  break ;;
        *) log_error "无效选项，请输入 1-5" ;;
    esac
done
log_info "已选择 TLS 指纹: ${CLIENT_FINGERPRINT}"

# =============================================================
# 交互 — 路由模式
# =============================================================
echo ""
print_line
echo -e "${BOLD}  请选择 sing-box 路由模式${NC}"
print_line
echo ""
echo -e "  ${GREEN}1)${NC} 全局代理     ${YELLOW}← 所有流量走代理${NC}"
echo -e "  ${GREEN}2)${NC} 分流模式     ${YELLOW}← 国内直连 + 国外代理 (推荐)${NC}"
echo ""

while true; do
    read -p "$(echo -e ${CYAN}'请输入选项 [1-2]（直接回车默认分流模式）: '${NC})" ROUTE_CHOICE
    ROUTE_CHOICE=${ROUTE_CHOICE:-2}
    case "$ROUTE_CHOICE" in
        1) ROUTE_MODE="global"; break ;;
        2) ROUTE_MODE="split";  break ;;
        *) log_error "无效选项，请输入 1-2" ;;
    esac
done
log_info "已选择路由模式: ${ROUTE_MODE}"

echo ""
log_info "即将安装 Xray 并生成 Reality 密钥对..."
echo ""

# =============================================================
# 安装 Xray
# =============================================================
log_step "开始安装 Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
log_info "Xray 安装完成"

# ---- 生成密钥对 ----
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep "Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYPAIR"  | grep "Public"  | awk '{print $NF}')

# ---- 生成 Short ID ----
SHORT_ID=$(openssl rand -hex 8)

# ---- 获取服务器 IP ----
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
         || curl -s --max-time 5 ip.sb 2>/dev/null \
         || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null \
         || echo "YOUR_SERVER_IP")

echo ""
print_dline
echo -e "${BOLD}${MAGENTA}  密钥信息（请妥善保存）${NC}"
print_dline
echo ""
echo -e "  UUID        : ${GREEN}${INPUT_UUID}${NC}"
echo -e "  Private Key : ${GREEN}${PRIVATE_KEY}${NC}"
echo -e "  Public Key  : ${GREEN}${PUBLIC_KEY}${NC}"
echo -e "  Short ID    : ${GREEN}${SHORT_ID}${NC}"
echo -e "  SNI         : ${GREEN}${INPUT_SNI}${NC}"
echo -e "  端口        : ${GREEN}${INPUT_PORT}${NC}"
echo -e "  客户端系统  : ${GREEN}${CLIENT_OS}${NC}"
echo -e "  TLS 指纹    : ${GREEN}${CLIENT_FINGERPRINT}${NC}"
echo -e "  路由模式    : ${GREEN}${ROUTE_MODE}${NC}"
echo -e "  服务器 IP   : ${GREEN}${SERVER_IP}${NC}"
echo ""
print_dline
echo ""

# =============================================================
# 写入 Xray 服务端配置
# =============================================================
log_step "写入 Xray 服务端配置文件..."

cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${INPUT_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${INPUT_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${INPUT_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${INPUT_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

log_info "服务端配置已写入 /usr/local/etc/xray/config.json"

# =============================================================
# 验证配置
# =============================================================
log_step "验证配置文件..."
if xray run -test -config /usr/local/etc/xray/config.json; then
    log_info "配置文件验证通过"
else
    log_error "配置文件验证失败，请检查"
    exit 1
fi

# =============================================================
# 防火墙放行端口
# =============================================================
log_step "配置防火墙..."
if command -v ufw &> /dev/null; then
    ufw allow ${INPUT_PORT}/tcp
    log_info "ufw 已放行端口 ${INPUT_PORT}"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=${INPUT_PORT}/tcp
    firewall-cmd --reload
    log_info "firewalld 已放行端口 ${INPUT_PORT}"
else
    log_warn "未检测到防火墙工具，请手动放行端口 ${INPUT_PORT}"
fi

# =============================================================
# 启动 Xray
# =============================================================
log_step "启动 Xray 服务..."
systemctl enable xray
systemctl restart xray

sleep 2

if systemctl is-active --quiet xray; then
    log_info "Xray 启动成功"
else
    log_error "Xray 启动失败，请查看日志: journalctl -u xray -f"
    exit 1
fi

if ss -tlnp | grep -q ":${INPUT_PORT}"; then
    log_info "端口 ${INPUT_PORT} 监听正常"
else
    log_warn "端口 ${INPUT_PORT} 未检测到监听，请检查: ss -tlnp | grep ${INPUT_PORT}"
fi

# =============================================================
# =============================================================
#
#   生成 sing-box 1.11+ 完整客户端配置
#
#   语法要点 (与旧版 1.8 的区别):
#     - DNS 服务器用 "type"+"server" 结构体，不再用 "address" URL
#     - TUN inbound 用 "address":[] 数组，不再用 inet4_address/inet6_address
#     - 嗅探在路由规则里用 { "action": "sniff" } 而非 inbound 里的 sniff 字段
#     - DNS 劫持用 { "protocol":"dns", "action":"hijack-dns" } 替代 dns-out
#     - route 中有 default_domain_resolver 字段
#
# =============================================================
# =============================================================

SINGBOX_CONFIG_DIR="/root/sing-box-config"
mkdir -p "${SINGBOX_CONFIG_DIR}"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config_${CLIENT_OS}.json"

# -----------------------------------------------------------------
# 生成 inbounds JSON 片段
# -----------------------------------------------------------------
generate_inbounds() {
    case "$CLIENT_OS" in

        # -----------------------------------------------------------
        # iOS: 纯 TUN
        # Network Extension 接管全部流量，不需要本地代理端口
        # -----------------------------------------------------------
        ios)
            cat << EOF
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true
    }
EOF
            ;;

        # -----------------------------------------------------------
        # macOS: TUN + mixed
        # interface_name 指定虚拟网卡名，macOS 通常用 utun0
        # mixed 入站供终端 export http_proxy / 浏览器手动代理
        # -----------------------------------------------------------
        macos)
            cat << EOF
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "utun0",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
EOF
            ;;

        # -----------------------------------------------------------
        # Android: 纯 TUN
        # VPN Service API 系统级接管所有 App 流量
        # -----------------------------------------------------------
        android)
            cat << EOF
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true
    }
EOF
            ;;

        # -----------------------------------------------------------
        # Windows: TUN + mixed
        # TUN 全局接管 + mixed 供 SwitchyOmega 等浏览器扩展
        # 需管理员权限运行，WinTun 驱动会自动安装
        # -----------------------------------------------------------
        windows)
            cat << EOF
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
EOF
            ;;

        # -----------------------------------------------------------
        # Linux: TUN + mixed + tproxy
        # mixed 供终端 export all_proxy 使用
        # tproxy 端口 7893 供旁路由/网关 iptables 透明代理
        # -----------------------------------------------------------
        linux)
            cat << EOF
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "auto_route": true,
      "strict_route": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    },
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "::",
      "listen_port": 7893
    }
EOF
            ;;
    esac
}

# -----------------------------------------------------------------
# 生成 DNS 配置 (sing-box 1.11+ 语法)
# -----------------------------------------------------------------
generate_dns() {
    case "$ROUTE_MODE" in

        global)
            cat << 'EOF'
  "dns": {
    "servers": [
      {
        "type": "tls",
        "tag": "dns-remote",
        "server": "8.8.8.8",
        "detour": "proxy"
      }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4"
  },
EOF
            ;;

        split)
            cat << 'EOF'
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-remote",
        "server": "8.8.8.8",
        "detour": "proxy"
      },
      {
        "type": "udp",
        "tag": "dns-local",
        "server": "223.5.5.5"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "server": "dns-local"
      }
    ],
    "final": "dns-remote",
    "strategy": "prefer_ipv4"
  },
EOF
            ;;
    esac
}

# -----------------------------------------------------------------
# 生成 route 配置 (sing-box 1.11+ 语法)
# -----------------------------------------------------------------
generate_route() {
    case "$ROUTE_MODE" in

        global)
            cat << 'EOF'
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-remote"
  }
EOF
            ;;

        split)
            cat << 'EOF'
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-cn", "outbound": "direct" }
    ],
    "rule_set": [
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "proxy"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs",
        "download_detour": "proxy"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-local"
  }
EOF
            ;;
    esac
}

# -----------------------------------------------------------------
# 组装完整 sing-box 客户端配置
# -----------------------------------------------------------------
log_step "生成 sing-box 客户端配置 (${CLIENT_OS} / ${ROUTE_MODE})..."

{
    cat << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
EOF

    # DNS 配置
    generate_dns

    # inbounds — 按客户端系统类型生成
    echo '  "inbounds": ['
    generate_inbounds
    echo '  ],'

    # outbounds — 所有平台相同
    cat << EOF
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_IP}",
      "server_port": ${INPUT_PORT},
      "uuid": "${INPUT_UUID}",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "tls": {
        "enabled": true,
        "server_name": "${INPUT_SNI}",
        "utls": { "enabled": true, "fingerprint": "${CLIENT_FINGERPRINT}" },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
EOF

    # route — 按路由模式生成
    generate_route

    echo '}'

} > "${SINGBOX_CONFIG_FILE}"

# 用 python3 格式化 JSON（如果可用）
if command -v python3 &> /dev/null; then
    python3 -m json.tool "${SINGBOX_CONFIG_FILE}" > "${SINGBOX_CONFIG_FILE}.tmp" 2>/dev/null \
        && mv "${SINGBOX_CONFIG_FILE}.tmp" "${SINGBOX_CONFIG_FILE}" \
        || rm -f "${SINGBOX_CONFIG_FILE}.tmp"
fi

log_info "sing-box 客户端配置已保存至: ${SINGBOX_CONFIG_FILE}"

# =============================================================
# 生成 VLESS 分享链接
# =============================================================
VLESS_LINK="vless://${INPUT_UUID}@${SERVER_IP}:${INPUT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${INPUT_SNI}&fp=${CLIENT_FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality-${CLIENT_OS}"

# =============================================================
# 最终输出
# =============================================================
echo ""
echo ""
print_dline
echo -e "${BOLD}${GREEN}              部署完成！${NC}"
print_dline

# ---- 1. 通用客户端参数 ----
echo ""
echo -e "${BOLD}${MAGENTA}  ▶ 1. 通用客户端参数${NC}"
print_line
echo ""
echo -e "  协议        : ${GREEN}VLESS${NC}"
echo -e "  服务器地址  : ${GREEN}${SERVER_IP}${NC}"
echo -e "  端口        : ${GREEN}${INPUT_PORT}${NC}"
echo -e "  UUID        : ${GREEN}${INPUT_UUID}${NC}"
echo -e "  Flow        : ${GREEN}xtls-rprx-vision${NC}"
echo -e "  传输协议    : ${GREEN}tcp${NC}"
echo -e "  TLS         : ${GREEN}reality${NC}"
echo -e "  SNI         : ${GREEN}${INPUT_SNI}${NC}"
echo -e "  Public Key  : ${GREEN}${PUBLIC_KEY}${NC}"
echo -e "  Short ID    : ${GREEN}${SHORT_ID}${NC}"
echo -e "  客户端系统  : ${GREEN}${CLIENT_OS}${NC}"
echo -e "  TLS 指纹    : ${GREEN}${CLIENT_FINGERPRINT}${NC}"
echo -e "  路由模式    : ${GREEN}${ROUTE_MODE}${NC}"
echo ""

# ---- 2. VLESS 分享链接 ----
echo -e "${BOLD}${MAGENTA}  ▶ 2. VLESS 分享链接${NC}"
echo -e "${DIM}  可直接导入 v2rayN / v2rayNG / NekoBox / Shadowrocket${NC}"
print_line
echo ""
echo -e "  ${GREEN}${VLESS_LINK}${NC}"
echo ""

# ---- 3. sing-box outbound 片段 ----
echo -e "${BOLD}${MAGENTA}  ▶ 3. sing-box outbound 配置片段${NC}"
print_line
echo ""
cat << EOF
  {
    "type": "vless",
    "tag": "proxy",
    "server": "${SERVER_IP}",
    "server_port": ${INPUT_PORT},
    "uuid": "${INPUT_UUID}",
    "flow": "xtls-rprx-vision",
    "packet_encoding": "xudp",
    "tls": {
      "enabled": true,
      "server_name": "${INPUT_SNI}",
      "utls": { "enabled": true, "fingerprint": "${CLIENT_FINGERPRINT}" },
      "reality": {
        "enabled": true,
        "public_key": "${PUBLIC_KEY}",
        "short_id": "${SHORT_ID}"
      }
    }
  }
EOF
echo ""

# ---- 4. 完整 sing-box JSON 配置 ----
echo -e "${BOLD}${MAGENTA}  ▶ 4. sing-box 完整客户端配置 [${CLIENT_OS} / ${ROUTE_MODE}]${NC}"
echo -e "  ${YELLOW}文件路径: ${SINGBOX_CONFIG_FILE}${NC}"
print_line
echo ""
cat "${SINGBOX_CONFIG_FILE}"
echo ""
print_line
echo ""

# ---- 5. 平台特定使用说明 ----
echo -e "${BOLD}${MAGENTA}  ▶ 5. ${CLIENT_OS} 平台使用说明${NC}"
print_line
echo ""
case "$CLIENT_OS" in
    ios)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box iOS / Stash / Shadowrocket${NC}"
        echo -e "  ${CYAN}导入方式 :${NC} 复制完整 JSON → App 中新建配置粘贴"
        echo -e "           或使用 VLESS 分享链接直接导入"
        echo -e "  ${CYAN}工作原理 :${NC} 系统通过 Network Extension 将全部流量交给 TUN 接口"
        echo -e "           无需手动设置系统代理，开启即全局生效"
        ;;
    macos)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box macOS (SFI)${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 使用 utun0 虚拟网卡接管全局流量"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080 (HTTP + SOCKS5)"
        echo -e "           终端使用: ${GREEN}export https_proxy=http://127.0.0.1:2080${NC}"
        echo -e "           浏览器可用 SwitchyOmega 指向此端口"
        echo -e "  ${CYAN}首次运行 :${NC} 需在 系统设置 → 隐私与安全性 → VPN 中授权"
        ;;
    android)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box Android / NekoBox / v2rayNG${NC}"
        echo -e "  ${CYAN}导入方式 :${NC} 复制完整 JSON → App 新建配置粘贴"
        echo -e "           或使用 VLESS 分享链接直接导入"
        echo -e "  ${CYAN}工作原理 :${NC} 通过 Android VPN Service 创建虚拟网卡"
        echo -e "           系统级接管所有 App 流量，可在 App 中设置分应用代理"
        ;;
    windows)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box Windows / v2rayN / NekoRay${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 全局接管系统流量（需管理员权限运行）"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080 (HTTP + SOCKS5)"
        echo -e "           浏览器可配合 SwitchyOmega 扩展使用"
        echo -e "  ${CYAN}注意事项 :${NC} 首次运行会自动安装 WinTun 网卡驱动"
        echo -e "           如 TUN 模式异常可先用 Mixed 代理模式"
        ;;
    linux)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box CLI${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 全局接管流量（需 root / CAP_NET_ADMIN）"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080 (HTTP + SOCKS5)"
        echo -e "           终端: ${GREEN}export all_proxy=socks5://127.0.0.1:2080${NC}"
        echo -e "  ${CYAN}TProxy   :${NC} 端口 7893，供旁路由/网关做透明代理"
        echo -e "           配合 iptables/nftables 将局域网流量转发到此端口"
        echo -e "  ${CYAN}启动命令 :${NC} ${GREEN}sudo sing-box run -c ${SINGBOX_CONFIG_FILE}${NC}"
        ;;
esac
echo ""

# ---- 6. 常用命令 ----
echo -e "${BOLD}${MAGENTA}  ▶ 6. 服务器常用命令${NC}"
print_line
echo ""
echo -e "  ${CYAN}查看 Xray 状态  :${NC} ${GREEN}systemctl status xray${NC}"
echo -e "  ${CYAN}查看 Xray 日志  :${NC} ${GREEN}journalctl -u xray -f${NC}"
echo -e "  ${CYAN}重启 Xray       :${NC} ${GREEN}systemctl restart xray${NC}"
echo -e "  ${CYAN}下载配置到本地  :${NC} ${GREEN}scp root@${SERVER_IP}:${SINGBOX_CONFIG_FILE} ./config.json${NC}"
echo -e "  ${CYAN}重新查看配置    :${NC} ${GREEN}cat ${SINGBOX_CONFIG_FILE}${NC}"
echo ""
print_dline
echo -e "${BOLD}${RED}  ⚠  请将以上所有信息保存好，私钥不会再次显示！${NC}"
print_dline
echo ""