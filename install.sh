#!/bin/bash

# =============================================================
# Xray 一键部署脚本 (增强版 v4 — 含 WARP)
# 协议: VLESS + Reality + XTLS Vision
# sing-box 配置语法: 1.11+
#
# 功能:
#   1. 部署 Xray VLESS+Reality 服务端
#   2. 安装 Cloudflare WARP 并配置 SOCKS5 代理出口
#   3. Xray 路由规则: ChatGPT / Claude 流量走 WARP 出口
#   4. 选择客户端系统类型 (iOS/macOS/Android/Windows/Linux)
#   5. 选择 TLS 指纹（根据系统自动推荐）
#   6. 选择路由模式（全局 / 国内外分流）
#   7. 终端完整显示 sing-box 客户端 JSON + 保存文件
#   8. 生成 VLESS 分享链接
#
# WARP 工作原理:
#   VPS 上安装 Cloudflare WARP 客户端后，它会在本地开一个
#   SOCKS5 代理端口 (127.0.0.1:40000)。Xray 服务端配置中
#   新增一个 "warp" outbound，通过这个 SOCKS5 端口将流量
#   转发给 Cloudflare 网络。路由规则指定 ChatGPT 和 Claude
#   相关域名走 warp outbound，其他流量仍然直连 (freedom)。
#
#   流量路径:
#     客户端 → Xray(VPS) → WARP SOCKS5 → Cloudflare网络 → 目标网站
#                         ↘ 其他流量直接出去 (freedom)
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
echo -e "${BOLD}${MAGENTA}     Xray VLESS + Reality 一键部署 (v4)${NC}"
echo -e "${DIM}     含 Cloudflare WARP · sing-box 1.11+ 语法${NC}"
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
# 交互 — 是否启用 WARP
# =============================================================
echo ""
print_line
echo -e "${BOLD}  Cloudflare WARP 配置${NC}"
echo -e "${DIM}  WARP 可以让指定流量通过 Cloudflare 干净 IP 出去${NC}"
echo -e "${DIM}  避免 VPS IP 被 ChatGPT / Claude 等服务封锁${NC}"
print_line
echo ""
echo -e "  ${GREEN}1)${NC} 启用 WARP   ${YELLOW}← 推荐：ChatGPT + Claude 走 WARP${NC}"
echo -e "  ${GREEN}2)${NC} 不启用      ${DIM}所有流量直接从 VPS IP 出去${NC}"
echo ""

while true; do
    read -p "$(echo -e ${CYAN}'请输入选项 [1-2]（直接回车默认启用）: '${NC})" WARP_CHOICE
    WARP_CHOICE=${WARP_CHOICE:-1}
    case "$WARP_CHOICE" in
        1) ENABLE_WARP=true;  break ;;
        2) ENABLE_WARP=false; break ;;
        *) log_error "无效选项，请输入 1-2" ;;
    esac
done

# 如果启用 WARP，询问 SOCKS5 端口
WARP_SOCKS_PORT=40000
if [ "$ENABLE_WARP" = true ]; then
    log_info "已选择启用 WARP"
    read -p "$(echo -e ${CYAN}'WARP SOCKS5 本地端口（直接回车使用默认 40000）: '${NC})" WARP_PORT_INPUT
    WARP_SOCKS_PORT=${WARP_PORT_INPUT:-40000}

    # 询问需要走 WARP 的服务
    echo ""
    echo -e "  ${BOLD}选择需要走 WARP 出口的服务:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ChatGPT + Claude          ${YELLOW}← 推荐${NC}"
    echo -e "  ${GREEN}2)${NC} ChatGPT + Claude + Google"
    echo -e "  ${GREEN}3)${NC} ChatGPT + Claude + Google + Netflix"
    echo -e "  ${GREEN}4)${NC} 全部流量走 WARP           ${DIM}(所有出站都经过 Cloudflare)${NC}"
    echo ""

    while true; do
        read -p "$(echo -e ${CYAN}'请输入选项 [1-4]（直接回车默认 1）: '${NC})" WARP_ROUTE_CHOICE
        WARP_ROUTE_CHOICE=${WARP_ROUTE_CHOICE:-1}
        case "$WARP_ROUTE_CHOICE" in
            1) WARP_ROUTE_MODE="ai";       break ;;
            2) WARP_ROUTE_MODE="ai+google"; break ;;
            3) WARP_ROUTE_MODE="ai+google+netflix"; break ;;
            4) WARP_ROUTE_MODE="all";      break ;;
            *) log_error "无效选项，请输入 1-4" ;;
        esac
    done
    log_info "WARP 路由模式: ${WARP_ROUTE_MODE}"
else
    log_info "已选择不启用 WARP"
fi

# =============================================================
# 交互 — 客户端系统类型
# =============================================================
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
# 交互 — TLS 指纹
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
echo -e "${DIM}  (已根据客户端系统推荐默认值)${NC}"
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
echo -e "${BOLD}  请选择 sing-box 客户端路由模式${NC}"
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
echo ""
print_line
echo -e "${BOLD}  配置汇总确认${NC}"
print_line
echo ""
echo -e "  UUID        : ${GREEN}${INPUT_UUID}${NC}"
echo -e "  端口        : ${GREEN}${INPUT_PORT}${NC}"
echo -e "  SNI         : ${GREEN}${INPUT_SNI}${NC}"
echo -e "  WARP        : ${GREEN}$([ "$ENABLE_WARP" = true ] && echo "启用 (${WARP_ROUTE_MODE})" || echo "未启用")${NC}"
echo -e "  客户端系统  : ${GREEN}${CLIENT_OS}${NC}"
echo -e "  TLS 指纹    : ${GREEN}${CLIENT_FINGERPRINT}${NC}"
echo -e "  路由模式    : ${GREEN}${ROUTE_MODE}${NC}"
echo ""
read -p "$(echo -e ${CYAN}'确认以上配置开始部署？[Y/n]: '${NC})" CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log_warn "已取消部署"
    exit 0
fi

echo ""
log_info "开始部署..."
echo ""

# =============================================================
# 安装系统依赖
# =============================================================
# Xray 安装脚本需要 unzip 来解压 release 包，curl 用于下载，
# openssl 用于生成 Short ID。很多精简版 VPS 镜像不预装这些工具，
# 如果缺失会导致后续步骤报错，所以在这里统一安装一遍。
log_step "安装系统依赖 (unzip, curl, openssl, wget)..."

if command -v apt-get &> /dev/null; then
    # Debian / Ubuntu 系
    apt-get update -y
    apt-get install -y unzip curl openssl wget ca-certificates
elif command -v yum &> /dev/null; then
    # CentOS / RHEL 系
    yum install -y unzip curl openssl wget ca-certificates
elif command -v dnf &> /dev/null; then
    # Fedora / 新版 RHEL 系
    dnf install -y unzip curl openssl wget ca-certificates
elif command -v apk &> /dev/null; then
    # Alpine
    apk add --no-cache unzip curl openssl wget ca-certificates
else
    log_warn "未识别的包管理器，请确保已安装: unzip curl openssl wget"
fi

log_info "系统依赖安装完成"

# =============================================================
# 安装 Xray
# =============================================================
log_step "安装 Xray..."
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
echo -e "  服务器 IP   : ${GREEN}${SERVER_IP}${NC}"
echo ""
print_dline
echo ""

# =============================================================
# 安装并配置 Cloudflare WARP (如果启用)
# =============================================================
if [ "$ENABLE_WARP" = true ]; then
    log_step "安装 Cloudflare WARP..."

    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_CODENAME"
    fi

    # 安装 WARP 客户端
    # 如果已安装则跳过下载步骤
    if ! command -v warp-cli &> /dev/null; then
        log_info "正在添加 Cloudflare WARP 仓库..."

        case "$OS_ID" in
            ubuntu|debian)
                # 添加 Cloudflare GPG key 和仓库
                curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${OS_VERSION} main" \
                    > /etc/apt/sources.list.d/cloudflare-client.list

                apt-get update
                apt-get install -y cloudflare-warp
                ;;
            centos|rhel|rocky|almalinux|fedora)
                rpm -ivh "https://pkg.cloudflareclient.com/cloudflare-release-el$(rpm -E %rhel).rpm" 2>/dev/null \
                    || rpm -ivh "https://pkg.cloudflareclient.com/cloudflare-release-el8.rpm"
                yum install -y cloudflare-warp || dnf install -y cloudflare-warp
                ;;
            *)
                log_error "不支持的系统: ${OS_ID}，请手动安装 cloudflare-warp"
                log_warn "跳过 WARP 安装，其他配置将继续..."
                ENABLE_WARP=false
                ;;
        esac
    else
        log_info "warp-cli 已安装，跳过安装步骤"
    fi

    # 配置 WARP（仅在安装成功时执行）
    if [ "$ENABLE_WARP" = true ] && command -v warp-cli &> /dev/null; then
        log_info "配置 WARP 客户端..."

        # 注册 WARP（如果尚未注册）
        # warp-cli 在未注册时 status 会报错，所以用注册命令来判断
        if ! warp-cli --accept-tos status 2>/dev/null | grep -q "Registration"; then
            log_info "注册 WARP..."
            warp-cli --accept-tos registration new 2>/dev/null || true
        else
            log_info "WARP 已注册，跳过注册步骤"
        fi

        # 设置为 proxy 模式（仅开 SOCKS5 端口，不接管系统全部流量）
        #
        # 这一步很关键：WARP 有两种运行模式
        #   - warp 模式：接管整个系统的网络流量（会影响 SSH 连接！）
        #   - proxy 模式：仅在本地开一个 SOCKS5 代理端口，不影响系统网络
        #
        # 我们选择 proxy 模式，让 Xray 通过 SOCKS5 端口选择性地转发流量
        log_info "设置 WARP 为 proxy 模式 (SOCKS5 端口: ${WARP_SOCKS_PORT})..."
        warp-cli --accept-tos mode proxy
        warp-cli --accept-tos proxy port ${WARP_SOCKS_PORT}

        # 连接 WARP
        log_info "连接 WARP..."
        warp-cli --accept-tos connect

        # 等待连接建立
        sleep 3

        # 验证 WARP 连接状态
        WARP_STATUS=$(warp-cli --accept-tos status 2>/dev/null || echo "unknown")
        if echo "$WARP_STATUS" | grep -qi "Connected"; then
            log_info "WARP 连接成功"

            # 验证 SOCKS5 端口是否在监听
            if ss -tlnp | grep -q ":${WARP_SOCKS_PORT}"; then
                log_info "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 监听正常"
            else
                log_warn "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 未检测到监听"
                log_warn "请稍后手动检查: ss -tlnp | grep ${WARP_SOCKS_PORT}"
            fi

            # 测试 WARP 出口 IP（通过 WARP SOCKS5 代理访问）
            WARP_IP=$(curl -s --max-time 10 --socks5 127.0.0.1:${WARP_SOCKS_PORT} ifconfig.me 2>/dev/null || echo "获取失败")
            log_info "WARP 出口 IP: ${WARP_IP}"
            if [ "$WARP_IP" != "$SERVER_IP" ] && [ "$WARP_IP" != "获取失败" ]; then
                log_info "WARP 出口 IP 与 VPS IP 不同，WARP 工作正常"
            else
                log_warn "WARP 出口 IP 可能异常，请稍后手动验证"
            fi
        else
            log_warn "WARP 连接状态异常: ${WARP_STATUS}"
            log_warn "请稍后手动检查: warp-cli status"
        fi

        # 设置 WARP 开机自启
        systemctl enable warp-svc 2>/dev/null || true

    fi
fi

# =============================================================
# 构建 WARP 相关的域名列表（用于 Xray 服务端路由规则）
# =============================================================
#
# 这些域名列表决定了哪些流量会被转发到 WARP SOCKS5 出口。
# 每个服务的域名来自实际抓包和官方文档，覆盖了 API、CDN、
# 认证、WebSocket 等所有必要的子域名。
#

# ChatGPT / OpenAI 相关域名
OPENAI_DOMAINS=(
    "openai.com"
    "chat.openai.com"
    "auth0.openai.com"
    "platform.openai.com"
    "api.openai.com"
    "chatgpt.com"
    "auth.openai.com"
    "operator.chatgpt.com"
    "ab.chatgpt.com"
    "cdn.oaistatic.com"
    "oaistatic.com"
    "oaiusercontent.com"
    "files.oaiusercontent.com"
    "sentry.io"
    "intercomcdn.com"
    "intercom.io"
    "featuregates.org"
    "statsigapi.net"
    "identrust.com"
)

# Claude / Anthropic 相关域名
CLAUDE_DOMAINS=(
    "anthropic.com"
    "claude.ai"
    "api.anthropic.com"
    "console.anthropic.com"
    "docs.anthropic.com"
    "support.anthropic.com"
    "cdn.anthropic.com"
    "statsig.anthropic.com"
    "servd-anthropic.b-cdn.net"
)

# Google 相关域名（可选）
GOOGLE_DOMAINS=(
    "google.com"
    "googleapis.com"
    "google.com.hk"
    "googleusercontent.com"
    "gstatic.com"
    "ggpht.com"
    "googlevideo.com"
    "youtube.com"
    "ytimg.com"
    "gmail.com"
    "google.co.jp"
)

# Netflix 相关域名（可选）
NETFLIX_DOMAINS=(
    "netflix.com"
    "netflix.net"
    "nflxvideo.net"
    "nflximg.net"
    "nflximg.com"
    "nflxext.com"
    "nflxso.net"
)

# =============================================================
# 根据用户选择组装 WARP 域名路由规则
# =============================================================
build_warp_domain_rules() {
    # 此函数生成 Xray 路由规则中的 domain 数组内容
    local ALL_WARP_DOMAINS=()

    if [ "$ENABLE_WARP" = true ]; then
        # ChatGPT + Claude 始终包含
        ALL_WARP_DOMAINS+=("${OPENAI_DOMAINS[@]}")
        ALL_WARP_DOMAINS+=("${CLAUDE_DOMAINS[@]}")

        # 根据选择追加 Google
        if [[ "$WARP_ROUTE_MODE" == "ai+google" || "$WARP_ROUTE_MODE" == "ai+google+netflix" ]]; then
            ALL_WARP_DOMAINS+=("${GOOGLE_DOMAINS[@]}")
        fi

        # 根据选择追加 Netflix
        if [[ "$WARP_ROUTE_MODE" == "ai+google+netflix" ]]; then
            ALL_WARP_DOMAINS+=("${NETFLIX_DOMAINS[@]}")
        fi
    fi

    # 输出为 JSON 数组格式
    local FIRST=true
    for domain in "${ALL_WARP_DOMAINS[@]}"; do
        if [ "$FIRST" = true ]; then
            echo -n "\"domain:${domain}\""
            FIRST=false
        else
            echo -n ", \"domain:${domain}\""
        fi
    done
}

# =============================================================
# 写入 Xray 服务端配置
# =============================================================
log_step "写入 Xray 服务端配置文件..."

# 根据是否启用 WARP 以及路由模式，生成不同的服务端配置
if [ "$ENABLE_WARP" = true ] && [ "$WARP_ROUTE_MODE" = "all" ]; then
    # ---- 全部流量走 WARP：default outbound 改为 warp ----
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
          "serverNames": ["${INPUT_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
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
      "protocol": "socks",
      "tag": "warp",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${WARP_SOCKS_PORT}
          }
        ]
      }
    },
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

elif [ "$ENABLE_WARP" = true ]; then
    # ---- 指定域名走 WARP，其他流量直连 ----
    # 先构建域名列表
    WARP_DOMAIN_JSON=$(build_warp_domain_rules)

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
          "serverNames": ["${INPUT_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
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
      "protocol": "socks",
      "tag": "warp",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": ${WARP_SOCKS_PORT}
          }
        ]
      }
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
        "domain": [${WARP_DOMAIN_JSON}],
        "outboundTag": "warp"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

else
    # ---- 不启用 WARP，纯 freedom 出站 ----
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
          "serverNames": ["${INPUT_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
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
fi

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
# 生成 sing-box 1.11+ 客户端配置
# =============================================================

SINGBOX_CONFIG_DIR="/root/sing-box-config"
mkdir -p "${SINGBOX_CONFIG_DIR}"
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config_${CLIENT_OS}.json"

# -----------------------------------------------------------------
# inbounds 生成（按客户端系统类型）
# -----------------------------------------------------------------
generate_inbounds() {
    case "$CLIENT_OS" in
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
# DNS 生成（按路由模式）
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
# route 生成（按路由模式）
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

    generate_dns

    echo '  "inbounds": ['
    generate_inbounds
    echo '  ],'

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

    generate_route

    echo '}'

} > "${SINGBOX_CONFIG_FILE}"

# 用 python3 格式化 JSON
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

# ---- 2. WARP 状态 ----
if [ "$ENABLE_WARP" = true ]; then
    echo -e "${BOLD}${MAGENTA}  ▶ 2. WARP 出口信息${NC}"
    print_line
    echo ""
    echo -e "  WARP 状态   : ${GREEN}已启用${NC}"
    echo -e "  SOCKS5 端口 : ${GREEN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo -e "  WARP 出口IP : ${GREEN}${WARP_IP:-未知}${NC}"
    echo -e "  VPS  原始IP : ${GREEN}${SERVER_IP}${NC}"
    echo -e "  路由模式    : ${GREEN}${WARP_ROUTE_MODE}${NC}"
    echo ""
    echo -e "  ${CYAN}经过 WARP 的域名:${NC}"
    case "$WARP_ROUTE_MODE" in
        ai)
            echo -e "    ${GREEN}✓${NC} ChatGPT (openai.com, chatgpt.com, ...)"
            echo -e "    ${GREEN}✓${NC} Claude  (anthropic.com, claude.ai, ...)"
            ;;
        ai+google)
            echo -e "    ${GREEN}✓${NC} ChatGPT (openai.com, chatgpt.com, ...)"
            echo -e "    ${GREEN}✓${NC} Claude  (anthropic.com, claude.ai, ...)"
            echo -e "    ${GREEN}✓${NC} Google  (google.com, youtube.com, ...)"
            ;;
        ai+google+netflix)
            echo -e "    ${GREEN}✓${NC} ChatGPT (openai.com, chatgpt.com, ...)"
            echo -e "    ${GREEN}✓${NC} Claude  (anthropic.com, claude.ai, ...)"
            echo -e "    ${GREEN}✓${NC} Google  (google.com, youtube.com, ...)"
            echo -e "    ${GREEN}✓${NC} Netflix (netflix.com, nflxvideo.net, ...)"
            ;;
        all)
            echo -e "    ${GREEN}✓${NC} 全部出站流量"
            ;;
    esac
    echo ""
else
    echo -e "${BOLD}${MAGENTA}  ▶ 2. WARP 状态${NC}"
    print_line
    echo ""
    echo -e "  WARP 状态   : ${YELLOW}未启用${NC}"
    echo -e "  所有流量通过 VPS IP (${SERVER_IP}) 直接出站"
    echo ""
fi

# ---- 3. VLESS 分享链接 ----
echo -e "${BOLD}${MAGENTA}  ▶ 3. VLESS 分享链接${NC}"
echo -e "${DIM}  可直接导入 v2rayN / v2rayNG / NekoBox / Shadowrocket${NC}"
print_line
echo ""
echo -e "  ${GREEN}${VLESS_LINK}${NC}"
echo ""

# ---- 4. sing-box outbound 片段 ----
echo -e "${BOLD}${MAGENTA}  ▶ 4. sing-box outbound 配置片段${NC}"
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

# ---- 5. 完整 sing-box 配置 ----
echo -e "${BOLD}${MAGENTA}  ▶ 5. sing-box 完整客户端配置 [${CLIENT_OS} / ${ROUTE_MODE}]${NC}"
echo -e "  ${YELLOW}文件路径: ${SINGBOX_CONFIG_FILE}${NC}"
print_line
echo ""
cat "${SINGBOX_CONFIG_FILE}"
echo ""
print_line
echo ""

# ---- 6. Xray 服务端配置 ----
echo -e "${BOLD}${MAGENTA}  ▶ 6. Xray 服务端配置${NC}"
echo -e "  ${YELLOW}文件路径: /usr/local/etc/xray/config.json${NC}"
print_line
echo ""
cat /usr/local/etc/xray/config.json
echo ""
print_line
echo ""

# ---- 7. 平台使用说明 ----
echo -e "${BOLD}${MAGENTA}  ▶ 7. ${CLIENT_OS} 平台使用说明${NC}"
print_line
echo ""
case "$CLIENT_OS" in
    ios)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box iOS / Stash / Shadowrocket${NC}"
        echo -e "  ${CYAN}导入方式 :${NC} 复制完整 JSON → App 中新建配置粘贴"
        echo -e "           或使用 VLESS 分享链接直接导入"
        echo -e "  ${CYAN}工作原理 :${NC} 系统通过 Network Extension 将全部流量交给 TUN 接口"
        ;;
    macos)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box macOS (SFI)${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 使用 utun0 虚拟网卡接管全局流量"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080 (HTTP + SOCKS5)"
        echo -e "           终端使用: ${GREEN}export https_proxy=http://127.0.0.1:2080${NC}"
        echo -e "  ${CYAN}首次运行 :${NC} 需在 系统设置 → 隐私与安全性 → VPN 中授权"
        ;;
    android)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box Android / NekoBox / v2rayNG${NC}"
        echo -e "  ${CYAN}导入方式 :${NC} 复制完整 JSON → App 新建配置粘贴"
        echo -e "           或使用 VLESS 分享链接直接导入"
        echo -e "  ${CYAN}工作原理 :${NC} 通过 Android VPN Service 创建虚拟网卡"
        ;;
    windows)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box Windows / v2rayN / NekoRay${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 全局接管系统流量（需管理员权限运行）"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080 (HTTP + SOCKS5)"
        echo -e "  ${CYAN}注意事项 :${NC} 首次运行会自动安装 WinTun 网卡驱动"
        ;;
    linux)
        echo -e "  ${CYAN}推荐客户端:${NC} ${GREEN}sing-box CLI${NC}"
        echo -e "  ${CYAN}TUN 入站 :${NC} 全局接管流量（需 root / CAP_NET_ADMIN）"
        echo -e "  ${CYAN}Mixed入站:${NC} 127.0.0.1:2080  终端: ${GREEN}export all_proxy=socks5://127.0.0.1:2080${NC}"
        echo -e "  ${CYAN}TProxy   :${NC} 端口 7893 供旁路由/网关透明代理"
        echo -e "  ${CYAN}启动命令 :${NC} ${GREEN}sudo sing-box run -c ${SINGBOX_CONFIG_FILE}${NC}"
        ;;
esac
echo ""

# ---- 8. 常用命令 ----
echo -e "${BOLD}${MAGENTA}  ▶ 8. 服务器常用命令${NC}"
print_line
echo ""
echo -e "  ${CYAN}Xray 状态      :${NC} ${GREEN}systemctl status xray${NC}"
echo -e "  ${CYAN}Xray 日志      :${NC} ${GREEN}journalctl -u xray -f${NC}"
echo -e "  ${CYAN}重启 Xray      :${NC} ${GREEN}systemctl restart xray${NC}"
echo -e "  ${CYAN}Xray 服务端配置:${NC} ${GREEN}cat /usr/local/etc/xray/config.json${NC}"
if [ "$ENABLE_WARP" = true ]; then
    echo -e "  ${CYAN}WARP 状态      :${NC} ${GREEN}warp-cli status${NC}"
    echo -e "  ${CYAN}WARP 重连      :${NC} ${GREEN}warp-cli disconnect && warp-cli connect${NC}"
    echo -e "  ${CYAN}测试 WARP IP   :${NC} ${GREEN}curl --socks5 127.0.0.1:${WARP_SOCKS_PORT} ifconfig.me${NC}"
fi
echo -e "  ${CYAN}下载客户端配置 :${NC} ${GREEN}scp root@${SERVER_IP}:${SINGBOX_CONFIG_FILE} ./config.json${NC}"
echo -e "  ${CYAN}查看客户端配置 :${NC} ${GREEN}cat ${SINGBOX_CONFIG_FILE}${NC}"
echo ""
print_dline
echo -e "${BOLD}${RED}  ⚠  请将以上所有信息保存好，私钥不会再次显示！${NC}"
print_dline
echo ""