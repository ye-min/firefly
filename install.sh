#!/bin/bash

# =============================================================
# Xray 一键部署脚本
# 协议: VLESS + Reality + XTLS Vision
# sing-box 客户端配置语法: 1.13+
#
# 版本: 1.0.0
# 日期: 2026-03-17
# 仓库: https://github.com/your-repo/xray-reality-setup
#
# 更新日志:
#   v1.0.0  2026-03-17  首个正式版本
#     - 一键部署 Xray VLESS+Reality 服务端
#     - Cloudflare WARP 集成 (ChatGPT/Claude/Google/Netflix)
#     - 客户端系统选择 (iOS/macOS/Android/Windows/Linux)
#     - TLS 指纹选择（根据系统自动推荐）
#     - 路由模式选择（全局代理 / 国内外分流）
#     - 生成完整 sing-box 1.13+ 客户端 JSON 配置
#     - 生成 VLESS 分享链接
#     - 系统依赖自动安装 (apt/yum/dnf，仅支持 systemd 环境)
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

# ---- 版本信息 ----
SCRIPT_VERSION="1.0.0"
SCRIPT_DATE="2026-03-17"

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
print_dline() { echo -e "${BLUE}=============================================${NC}"; }

# =============================================================
# 检查 root 权限
# =============================================================
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 官方 Xray 安装器及后续服务管理均依赖 systemd。
if ! command -v systemctl >/dev/null 2>&1 \
    || [ ! -d /run/systemd/system ]; then
    log_error "此脚本需要正在运行的 systemd，不支持 Alpine/OpenRC 环境"
    exit 1
fi

# 仅允许全新安装；检查必须在更新软件包和修改系统之前执行。
check_existing_installation() {
    local name path state
    local -a found=()
    for name in xray warp-cli warp-svc; do
        if command -v "$name" >/dev/null 2>&1; then
            found+=("程序: $name")
        fi
    done
    for path in /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray \
        /usr/local/lib/xray /var/log/xray /root/sing-box-config \
        /etc/cloudflare-warp /var/lib/cloudflare-warp /var/log/cloudflare-warp \
        /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
        /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
        /etc/systemd/system/warp-svc.service; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            found+=("安装文件或残留: $path")
        fi
    done
    for name in xray.service xray@.service warp-svc.service; do
        state=$(systemctl show "$name" --property=LoadState --value 2>/dev/null) || state=""
        if [ -n "$state" ] && [ "$state" != not-found ]; then
            found+=("systemd 服务: $name")
        fi
    done
    if command -v dpkg-query >/dev/null 2>&1 \
        && dpkg-query -W -f='${Status}' cloudflare-warp 2>/dev/null | grep -q 'install ok installed'; then
        found+=("软件包: cloudflare-warp")
    elif command -v rpm >/dev/null 2>&1 && rpm -q cloudflare-warp >/dev/null 2>&1; then
        found+=("软件包: cloudflare-warp")
    fi
    if [ "${#found[@]}" -gt 0 ]; then
        log_error "检测到 Xray / WARP 已安装或存在残留，本脚本仅支持全新安装。"
        printf '  - %s\n' "${found[@]}"
        log_warn "请先运行 sudo bash uninstall.sh，确认卸载干净后再运行 install.sh。"
        return 1
    fi
}
check_existing_installation

# =============================================================
# 系统更新与依赖安装
# =============================================================
# 很多 VPS 刚开出来的镜像是几个月前的快照，包索引过期、
# 软件版本陈旧，容易引发后续安装失败（例如缺少 unzip
# 导致 Xray 安装报错，或旧版 libssl 导致 WARP 安装失败）。
# 所以在最开始就做一次完整的系统更新。
# =============================================================
log_step "更新系统软件包..."

if command -v apt-get &> /dev/null; then
    # Debian / Ubuntu 系
    apt-get update -y
    log_info "包索引已更新"
    # upgrade 遇到包冲突时可能非零退出，不应中断脚本
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || \
        log_warn "系统软件包升级过程中有警告，继续执行..."
    log_info "系统软件包已升级"
    apt-get install -y unzip curl openssl wget ca-certificates gnupg lsb-release iproute2
elif command -v dnf &> /dev/null; then
    # Fedora / 新版 RHEL 系（dnf 优先于 yum，因为 yum 在 RHEL8+ 仅是 dnf 的别名）
    dnf update -y
    dnf install -y unzip curl openssl wget ca-certificates gnupg2 iproute
elif command -v yum &> /dev/null; then
    # CentOS / RHEL 旧版
    yum update -y
    yum install -y unzip curl openssl wget ca-certificates gnupg2 iproute
else
    log_warn "未识别的包管理器，请确保系统已更新且已安装: unzip curl openssl wget"
fi

log_info "系统更新与依赖安装完成"
echo ""

check_tcp_port_available() {
    local port="$1" listeners
    if ! listeners=$(ss -H -ltn "sport = :${port}"); then
        log_error "无法检查 TCP 端口 ${port}；请确认已安装 iproute2/iproute，且 ss 可以运行"
        return 1
    fi
    if [ -n "$listeners" ]; then
        log_error "TCP 端口 ${port} 已被占用，请停止占用进程或选择其他端口"
        return 1
    fi
    return 0
}

# =============================================================
# 欢迎界面
# =============================================================
clear
echo ""
print_dline
echo -e "${BOLD}${MAGENTA}     Xray VLESS + Reality 一键部署${NC}"
echo -e "${DIM}     含 Cloudflare WARP · sing-box 1.13+ 语法${NC}"
echo -e "${DIM}     版本 ${SCRIPT_VERSION}  (${SCRIPT_DATE})${NC}"
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
    # 去掉前导零；限制有效位数，避免超长数字触发整数比较错误。
    INPUT_PORT=$(printf '%s' "$INPUT_PORT" | sed 's/^0*//')
    if [[ "$INPUT_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then
        break
    else
        log_error "端口号必须在 1-65535 之间"
    fi
done

# ---- SNI ----
is_valid_sni() {
    local LC_ALL=C domain="$1"
    # 裸域名总长不超过 253，每段 1-63 字符，连字符不能位于段首或段尾。
    [[ ${#domain} -le 253 && "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
        && [[ ! "$domain" =~ ^[0-9.]+$ ]]
}

while true; do
    IFS= read -r -p "$(echo -e ${CYAN}'请输入 SNI 域名（直接回车使用默认 cdn.jsdelivr.net）: '${NC})" INPUT_SNI
    INPUT_SNI=${INPUT_SNI:-cdn.jsdelivr.net}
    if is_valid_sni "$INPUT_SNI"; then
        break
    fi
    log_error "SNI 必须是有效的裸域名（如 cdn.jsdelivr.net），不能包含协议、端口、路径、空格或引号，也不能使用 IP 地址"
done

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
    while true; do
        read -p "$(echo -e ${CYAN}'WARP SOCKS5 本地端口（直接回车使用默认 40000）: '${NC})" WARP_PORT_INPUT
        WARP_SOCKS_PORT=${WARP_PORT_INPUT:-40000}
        # 去掉前导零；限制有效位数，避免超长数字触发整数比较错误。
        WARP_SOCKS_PORT=$(printf '%s' "$WARP_SOCKS_PORT" | sed 's/^0*//')
        if [[ "$WARP_SOCKS_PORT" =~ ^[0-9]{1,5}$ ]] && [ "$WARP_SOCKS_PORT" -ge 1 ] && [ "$WARP_SOCKS_PORT" -le 65535 ]; then
            if [ "$WARP_SOCKS_PORT" -eq "$INPUT_PORT" ]; then
                log_error "WARP SOCKS5 端口不能与 Xray 监听端口相同，请重新输入"
                continue
            fi
            break
        else
            log_error "端口号必须在 1-65535 之间"
        fi
    done

    # 询问需要走 WARP 的服务
    echo ""
    echo -e "  ${BOLD}选择需要走 WARP 出口的服务:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} ChatGPT + Claude + Apple          ${YELLOW}← 推荐${NC}"
    echo -e "  ${GREEN}2)${NC} ChatGPT + Claude + Apple + Google"
    echo -e "  ${GREEN}3)${NC} ChatGPT + Claude + Apple + Google + Netflix"
    echo -e "  ${GREEN}4)${NC} 全部流量走 WARP                   ${DIM}(所有出站都经过 Cloudflare)${NC}"
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

# 在安装 Xray/WARP 前检查两个端口，避免部署到一半才发现冲突。
check_tcp_port_available "$INPUT_PORT"
if [ "$ENABLE_WARP" = true ]; then
    check_tcp_port_available "$WARP_SOCKS_PORT"
fi

echo ""
log_info "开始部署..."
echo ""

# =============================================================
# 安装 Xray
# =============================================================
# 记录安装器运行前是否已有配置，避免把首次安装产生的占位配置当作可回滚配置。
XRAY_CONFIG=/usr/local/etc/xray/config.json
XRAY_HAD_CONFIG=false
[ ! -f "$XRAY_CONFIG" ] || XRAY_HAD_CONFIG=true
XRAY_INSTALLER=""
XRAY_CANDIDATE=""
INSTALLATION_STARTED=false
finish_installation() {
    local status=$?
    # 只清理本次临时文件，不自动卸载或删除服务配置。
    if [ -n "$XRAY_INSTALLER" ]; then rm -f -- "$XRAY_INSTALLER" || true; fi
    if [ -n "$XRAY_CANDIDATE" ]; then rm -f -- "$XRAY_CANDIDATE" || true; fi
    if [ "$status" -ne 0 ] && [ "$INSTALLATION_STARTED" = true ]; then
        log_warn "本次部署未完成，可能已留下 Xray/WARP 安装文件。本脚本仅支持全新安装。"
        log_warn "排查原因后，请先运行 sudo bash uninstall.sh，确认卸载成功，再运行 sudo bash install.sh。"
    fi
    return "$status"
}
trap finish_installation EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log_step "安装 Xray..."
install_xray() {
    local status=0
    XRAY_INSTALLER=$(mktemp) || return 1
    if ! curl -fsSL --connect-timeout 10 --max-time 60 \
        https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$XRAY_INSTALLER"; then
        rm -f -- "$XRAY_INSTALLER"
        log_error "下载 Xray 安装器失败，尚未运行安装器；请检查网络后重试"
        return 1
    fi
    if [ ! -s "$XRAY_INSTALLER" ] || ! bash -n "$XRAY_INSTALLER"; then
        rm -f -- "$XRAY_INSTALLER"
        log_error "Xray 安装器为空或语法不完整，停止部署"
        return 1
    fi
    INSTALLATION_STARTED=true
    bash "$XRAY_INSTALLER" install || status=$?
    rm -f -- "$XRAY_INSTALLER"
    if [ "$status" -ne 0 ]; then
        log_error "Xray 安装器执行失败（退出码: ${status}）"
        return "$status"
    fi
    if ! command -v xray >/dev/null 2>&1; then
        log_error "Xray 安装器已退出，但找不到 xray 程序，停止部署"
        return 1
    fi
}
install_xray
log_info "Xray 安装完成"

# ---- 生成密钥对 ----
# 兼容 Private key / PrivateKey，以及 Public key / PublicKey /
# Password / Password (PublicKey)；仅匹配字段名，不将 Hash32 当作公钥。
if ! KEYPAIR=$(xray x25519); then
    log_error "xray x25519 执行失败，无法生成密钥对"
    exit 1
fi
PRIVATE_KEY=$(printf '%s\n' "$KEYPAIR" | sed -nE 's/^[[:space:]]*[Pp]rivate[[:space:]]*[Kk]ey:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p')
PUBLIC_KEY=$(printf '%s\n' "$KEYPAIR" | sed -nE 's/^[[:space:]]*([Pp]ublic[[:space:]]*[Kk]ey|[Pp]assword([[:space:]]*\([Pp]ublic[Kk]ey\))?):[[:space:]]*([^[:space:]]+)[[:space:]]*$/\3/p')

# X25519 的 32 字节密钥编码为无填充 Base64URL 后应为 43 个字符。
# 未知字段、空值、重复字段或异常格式均停止部署，不输出包含私钥的原文。
if [[ ! "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ || ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    log_error "无法识别 xray x25519 的密钥输出，或密钥格式异常；部署已停止。请检查 Xray 版本及输出字段名称（不要公开私钥）"
    exit 1
fi

# ---- 生成 Short ID ----
SHORT_ID=$(openssl rand -hex 8)

# ---- 获取服务器 IP ----
# 强制 IPv4：服务端监听 0.0.0.0（仅 IPv4），且 IPv6 地址写入
# VLESS 链接时需要加方括号，统一取 IPv4 避免生成不可用的配置
is_valid_ipv4() {
    local candidate="$1" octet
    local -a octets
    [[ "$candidate" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$candidate"
    for octet in "${octets[@]}"; do
        # 拒绝前导零，避免客户端对地址产生不同解释。
        if [[ ${#octet} -gt 1 && "$octet" == 0* ]] || (( 10#$octet > 255 )); then
            return 1
        fi
    done
    return 0
}

get_server_ipv4() {
    local url candidate
    for url in https://ifconfig.me/ip https://api.ip.sb/ip https://ipinfo.io/ip; do
        candidate=$(curl -4fsS --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || continue
        if is_valid_ipv4 "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! SERVER_IP=$(get_server_ipv4); then
    log_error "所有公网 IP 接口均请求失败或返回无效 IPv4，停止部署。请检查网络。"
    exit 1
fi

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
verify_warp_proxy() {
    local listeners trace candidate
    listeners=$(ss -H -ltn "sport = :${WARP_SOCKS_PORT}") || return 1
    [ -n "$listeners" ] || return 1

    # 禁用 curlrc 和 NO_PROXY 绕过，确保探测实际经过指定 SOCKS5。
    # 使用 IPv4 目标，避免 SOCKS5 远程解析选用 IPv6；trace 验证实际 WARP 出口。
    trace=$(curl --disable -4fsS --connect-timeout 3 --max-time 8 \
        --noproxy "" --proxy "socks5h://127.0.0.1:${WARP_SOCKS_PORT}" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null) || return 1
    printf '%s\n' "$trace" | grep -Eq '^warp=(on|plus)$' || return 1
    candidate=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p')
    is_valid_ipv4 "$candidate" || return 1
    WARP_IP="$candidate"
}

install_warp_rpm() {
    local manager major repo_content
    if command -v dnf >/dev/null 2>&1; then
        manager=dnf
    else
        manager=yum
    fi

    if [ "$OS_ID" != fedora ]; then
        major=${VERSION_ID%%.*}
        case "$major" in
            9|10) ;;
            *)
                log_error "Cloudflare 当前支持 EL 9/10；此系统版本不受支持: ${VERSION_ID}"
                return 1
                ;;
        esac
        # RHEL 系 WARP 的桌面组件依赖 EPEL；Fedora 使用自身仓库。
        if ! rpm -q epel-release >/dev/null 2>&1; then
            "$manager" install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${major}.noarch.rpm" || return 1
        fi
    fi

    # 官方提供 .repo 文件，不提供 cloudflare-release-el*.rpm。
    if ! repo_content=$(curl -fsSL --connect-timeout 10 --max-time 60 \
        https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo) || [ -z "$repo_content" ]; then
        log_error "下载 Cloudflare WARP 软件源失败"
        return 1
    fi
    if [ "$OS_ID" != fedora ]; then
        # RHEL 的 releasever 可能包含次版本号，Cloudflare 仓库使用主版本。
        repo_content=${repo_content//\$releasever/$major}
    fi
    printf '%s\n' "$repo_content" > /etc/yum.repos.d/cloudflare-warp.repo || return 1
    if ! "$manager" install -y cloudflare-warp; then
        log_error "WARP 软件包安装失败；EL 系统请确认 EPEL 和 CRB/CodeReady Builder 依赖仓库可用"
        return 1
    fi
}

if [ "$ENABLE_WARP" = true ]; then
    log_step "安装 Cloudflare WARP..."

    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        # VERSION_CODENAME 在部分最小化镜像中可能为空，回退到 lsb_release
        OS_VERSION="${VERSION_CODENAME:-}"
        if [ -z "$OS_VERSION" ] && command -v lsb_release &> /dev/null; then
            OS_VERSION=$(lsb_release -cs 2>/dev/null || true)
        fi
    fi

    # 安装 WARP 客户端
    # 如果已安装则跳过下载步骤
    if ! command -v warp-cli &> /dev/null; then
        log_info "正在添加 Cloudflare WARP 仓库..."

        case "$OS_ID" in
            ubuntu|debian)
                if [ -z "$OS_VERSION" ]; then
                    log_error "无法获取系统版本代号（VERSION_CODENAME 为空），请检查 /etc/os-release 或 lsb_release"
                    log_error "WARP 无法安装，停止部署；请按退出提示清理后重新安装。"
                    exit 1
                else
                    # 添加 Cloudflare GPG key 和仓库
                    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                        | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

                    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${OS_VERSION} main" \
                        > /etc/apt/sources.list.d/cloudflare-client.list

                    apt-get update
                    apt-get install -y cloudflare-warp
                fi
                ;;
            centos|rhel|rocky|almalinux|fedora)
                install_warp_rpm
                ;;
            *)
                log_error "不支持的系统: ${OS_ID}；请使用受支持的发行版，或重新安装时选择不启用 WARP"
                log_error "WARP 无法安装，停止部署；请按退出提示清理后重新安装。"
                exit 1
                ;;
        esac
    else
        log_info "warp-cli 已安装，跳过安装步骤"
    fi

    if ! command -v warp-cli >/dev/null 2>&1; then
        log_error "WARP 安装后仍找不到 warp-cli，停止部署"
        exit 1
    fi

    # 配置 WARP（仅在安装成功时执行）
    if [ "$ENABLE_WARP" = true ] && command -v warp-cli &> /dev/null; then
        log_info "配置 WARP 客户端..."

        # 全新安装只创建注册，不删除或覆盖已有注册。
        # 先确认守护进程和注册状态，不能把通信失败当成未注册。
        create_warp_registration() {
            local registration_info registration_state="" i
            if ! systemctl enable --now warp-svc; then
                log_error "无法启动 WARP 守护进程，停止部署"
                return 1
            fi
            log_info "等待 WARP 守护进程就绪..."
            for i in $(seq 1 15); do
                if registration_info=$(LC_ALL=C warp-cli --accept-tos registration show 2>&1); then
                    registration_state="registered"
                    break
                elif printf '%s\n' "$registration_info" | grep -Eqi 'missing[[:space:]]+registration|registration[[:space:]]+missing' \
                    && ! printf '%s\n' "$registration_info" | grep -qi "Daemon Startup"; then
                    registration_state="missing"
                    break
                fi
                sleep 2
            done
            if [ -z "$registration_state" ]; then
                log_error "无法确认 WARP 注册状态，停止部署；请检查 warp-svc 日志"
                return 1
            fi

            if [ "$registration_state" = registered ]; then
                log_error "检测到已有 WARP 注册，请先运行 uninstall.sh 后重新安装。"
                return 1
            fi
            log_info "创建新的 WARP 注册..."
            if ! warp-cli --accept-tos registration new; then
                log_error "WARP 注册失败，停止部署；请先运行 uninstall.sh 清理后重新安装"
                return 1
            fi
            log_info "WARP 新注册已创建"
        }
        create_warp_registration

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

        # 连接 WARP（连接失败不应立即中断脚本，下方重试循环会检测连接状态）
        log_info "连接 WARP..."
        warp-cli --accept-tos connect || true

        # 同时等待状态、SOCKS5 监听和实际 WARP 出口就绪。
        # 每次网络探测有独立超时，不能把重试间隔当作总等待时间。
        WARP_CONNECTED=false
        log_info "等待 WARP 连接并验证出口（最多检查 15 次）..."
        for i in $(seq 1 15); do
            WARP_STATUS=$(LC_ALL=C warp-cli --accept-tos status 2>/dev/null) || WARP_STATUS="unknown"
            if printf '%s\n' "$WARP_STATUS" | grep -qi "Connected" \
                && ! printf '%s\n' "$WARP_STATUS" | grep -qi "Disconnected" \
                && verify_warp_proxy; then
                WARP_CONNECTED=true
                log_info "WARP SOCKS5 和出口验证通过，出口 IPv4: ${WARP_IP}"
                break
            fi
            if [ "$i" -lt 15 ]; then sleep 2; fi
        done

        if [ "$WARP_CONNECTED" != true ]; then
            log_warn "WARP 连接或出口验证失败（已检查 15 次）"
            log_warn "最后状态: ${WARP_STATUS}"
            log_warn ""
            log_warn "请排查 WARP 守护进程、端口和网络连通性；以下命令可用于诊断:"
            log_warn "  warp-cli disconnect"
            log_warn "  warp-cli mode proxy"
            log_warn "  warp-cli proxy port ${WARP_SOCKS_PORT}"
            log_warn "  warp-cli connect"
            log_warn "  warp-cli status"
            log_warn "  curl --noproxy '' --proxy socks5h://127.0.0.1:${WARP_SOCKS_PORT} https://1.1.1.1/cdn-cgi/trace"
            log_error "WARP 未通过连通性验证，停止部署；不会自动改为直连。"
            exit 1
        fi


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

# Apple 相关域名（账号注册 / iCloud / App Store）
APPLE_DOMAINS=(
    "apple.com"
    "icloud.com"
    "mzstatic.com"
    "cdn-apple.com"
    "apple-cloudkit.com"
    "icloud-content.com"
)

# =============================================================
# 根据用户选择组装 WARP 域名路由规则
# =============================================================
build_warp_domain_rules() {
    # 此函数生成 Xray 路由规则中的 domain 数组内容
    local ALL_WARP_DOMAINS=()

    if [ "$ENABLE_WARP" = true ]; then
        # ChatGPT + Claude + Apple 始终包含（模式 1/2/3 均含 Apple）
        ALL_WARP_DOMAINS+=("${OPENAI_DOMAINS[@]}")
        ALL_WARP_DOMAINS+=("${CLAUDE_DOMAINS[@]}")
        ALL_WARP_DOMAINS+=("${APPLE_DOMAINS[@]}")

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
secure_xray_config() {
    local path="$1" service_user service_uid
    if ! service_user=$(systemctl show xray.service --property=User --value); then
        log_error "无法读取 Xray 服务账户，停止设置配置权限"
        return 1
    fi
    # systemd 系统服务未设置 User 时以 root 运行。
    service_user=${service_user:-root}
    service_uid=$(id -u "$service_user") || return 1
    # 服务账户只读，root 仍可管理；不向同组或其他用户开放密钥。
    chmod 400 "$path" || return 1
    chown "${service_uid}:0" "$path"
}

log_step "生成 Xray 服务端候选配置..."
# mktemp 的 root/600 权限保护写入过程，完成后再授予服务账户读取权限。
XRAY_CANDIDATE=$(mktemp "${XRAY_CONFIG}.new.XXXXXX")

# 根据是否启用 WARP 以及路由模式，生成不同的服务端配置
if [ "$ENABLE_WARP" = true ] && [ "$WARP_ROUTE_MODE" = "all" ]; then
    # ---- 全部流量走 WARP：default outbound 改为 warp ----
    cat > "$XRAY_CANDIDATE" << EOF
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

    cat > "$XRAY_CANDIDATE" << EOF
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
    cat > "$XRAY_CANDIDATE" << EOF
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

secure_xray_config "$XRAY_CANDIDATE"
log_info "服务端候选配置已生成"

# =============================================================
# 验证配置
# =============================================================
log_step "验证配置文件..."
# mktemp 生成的文件以随机字符结尾，必须显式指定 JSON 格式。
if xray run -test -format json -config "$XRAY_CANDIDATE"; then
    log_info "配置文件验证通过"
else
    log_error "配置文件验证失败，请检查"
    exit 1
fi

# =============================================================
# 防火墙放行端口
# =============================================================
log_step "配置防火墙..."
configure_firewall() {
    local port="$1" ufw_status configured=false
    local addresses route_info interface zone
    if command -v ufw >/dev/null 2>&1; then
        if ! ufw_status=$(LC_ALL=C ufw status); then
            log_error "无法读取 UFW 状态，停止部署"
            return 1
        fi
        if printf '%s\n' "$ufw_status" | grep -q '^Status: active$'; then
            ufw allow "${port}/tcp" || return 1
            log_info "ufw 已放行端口 ${port}"
            configured=true
        fi
    fi
    # 两种防火墙都启用时分别放行；不启动原本停用的防火墙。
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        # 优先匹配服务器公网地址；使用 NAT 的 VPS 则通过公网路由确定网卡。
        if ! addresses=$(ip -o -4 addr show); then
            log_error "无法读取网卡地址，停止配置 firewalld"
            return 1
        fi
        interface=$(printf '%s\n' "$addresses" | awk -v server_ip="$SERVER_IP" '
            $3 == "inet" { split($4, address, "/"); if (address[1] == server_ip) { print $2; exit } }')
        if [ -z "$interface" ]; then
            if ! route_info=$(ip -4 route get 1.1.1.1); then
                log_error "无法确定公网路由网卡，停止配置 firewalld"
                return 1
            fi
            interface=$(printf '%s\n' "$route_info" | awk '
                { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        fi
        interface=${interface%%@*}
        if [ -z "$interface" ]; then
            log_error "无法确定公网网卡，停止配置 firewalld"
            return 1
        fi

        if zone=$(LC_ALL=C firewall-cmd --get-zone-of-interface="$interface"); then
            :
        elif [ "$zone" != "no zone" ]; then
            log_error "无法查询网卡 ${interface} 的 firewalld zone，停止部署"
            return 1
        fi
        # 未显式绑定 zone 的网卡使用默认区域；查询失败不能当作未绑定。
        if [ "$zone" = "no zone" ]; then
            zone=$(firewall-cmd --get-default-zone) || return 1
        fi
        if [ -z "$zone" ]; then
            log_error "firewalld 返回空 zone，停止部署"
            return 1
        fi
        firewall-cmd --permanent --zone="$zone" --add-port="${port}/tcp" || return 1
        firewall-cmd --zone="$zone" --add-port="${port}/tcp" || return 1
        log_info "firewalld 已在 ${interface} 所属 zone ${zone} 放行端口 ${port}（持久和运行时规则）"
        configured=true
    fi
    if [ "$configured" = false ]; then
        log_warn "未检测到启用的 UFW/firewalld；请确认其他防火墙及云安全组放行端口 ${port}"
    fi
}
configure_firewall "$INPUT_PORT"

# =============================================================
# 启动 Xray
# =============================================================
log_step "启动 Xray 服务..."
systemctl enable xray
XRAY_BACKUP=""
if [ "$XRAY_HAD_CONFIG" = true ]; then
    XRAY_BACKUP=$(mktemp "${XRAY_CONFIG}.backup.XXXXXX")
    cp -p "$XRAY_CONFIG" "$XRAY_BACKUP"
    log_info "原配置已备份: ${XRAY_BACKUP}"
fi
# 同目录重命名，避免正式配置出现部分写入状态。
mv -f "$XRAY_CANDIDATE" "$XRAY_CONFIG"
if systemctl restart xray && sleep 2 && systemctl is-active --quiet xray; then
    log_info "Xray 启动成功"
    if [ "$XRAY_HAD_CONFIG" = true ]; then
        log_warn "重新部署已生成新密钥和 Short ID，请更新客户端配置。"
    fi
else
    log_error "新配置启动失败，请查看日志: journalctl -u xray -n 50 --no-pager"
    if [ -n "$XRAY_BACKUP" ]; then
        # 通过临时文件恢复，保留备份供后续排查。
        if cp -p "$XRAY_BACKUP" "$XRAY_CANDIDATE" && mv -f "$XRAY_CANDIDATE" "$XRAY_CONFIG"; then
            if systemctl restart xray && sleep 2 && systemctl is-active --quiet xray; then
                log_warn "已恢复原配置，Xray 服务已重新启动。部署未完成。"
            else
                log_error "原配置已恢复，但 Xray 仍无法启动，请检查服务日志。"
            fi
        else
            log_error "恢复原配置失败，请手动恢复备份: ${XRAY_BACKUP}"
        fi
    else
        log_error "首次安装没有原配置可恢复，请检查当前配置和服务日志。"
    fi
    exit 1
fi

if XRAY_LISTENERS=$(ss -H -ltn4 "sport = :${INPUT_PORT}") && [ -n "$XRAY_LISTENERS" ]; then
    log_info "端口 ${INPUT_PORT} 监听正常"
else
    log_error "端口 ${INPUT_PORT} 未检测到监听，停止部署；请检查 Xray 服务日志"
    exit 1
fi

# =============================================================
# 生成 sing-box 1.13+ 客户端配置
# =============================================================

SINGBOX_CONFIG_DIR="/root/sing-box-config"
mkdir -p "${SINGBOX_CONFIG_DIR}"

# -----------------------------------------------------------------
# 各 OS 的默认 TLS 指纹
# 用法: get_default_fp <os>
# -----------------------------------------------------------------
get_default_fp() {
    case "$1" in
        ios)     echo "safari"  ;;
        macos)   echo "chrome"  ;;
        android) echo "chrome"  ;;
        windows) echo "chrome"  ;;
        linux)   echo "firefox" ;;
        *)       echo "chrome"  ;;
    esac
}

# -----------------------------------------------------------------
# inbounds 生成
# 用法: generate_inbounds <os>
# -----------------------------------------------------------------
generate_inbounds() {
    local os="$1"
    case "$os" in
        ios)
            cat << 'EOF'
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
            cat << 'EOF'
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
        android)
            cat << 'EOF'
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
            cat << 'EOF'
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
            cat << 'EOF'
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
# DNS 生成
# 用法: generate_dns <route_mode>
# -----------------------------------------------------------------
generate_dns() {
    local mode="$1"
    case "$mode" in
        global)
            cat << 'EOF'
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-remote",
        "server": "8.8.8.8",
        "detour": "proxy"
      }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
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
    "strategy": "ipv4_only"
  },
EOF
            ;;
    esac
}

# -----------------------------------------------------------------
# route 生成
# 严格按照实际可工作的 sing-box 1.13+ 配置模板
# 用法: generate_route <route_mode>
# -----------------------------------------------------------------
generate_route() {
    local mode="$1"
    case "$mode" in
        global)
            cat << 'EOF'
  "route": {
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" }
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
# 组装并写入单个 sing-box 客户端配置
# 用法: generate_singbox_config <os> <route_mode> <fingerprint> <output_file>
# -----------------------------------------------------------------
generate_singbox_config() {
    local os="$1"
    local mode="$2"
    local fp="$3"
    local outfile="$4"

    {
        cat << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
EOF
        generate_dns "$mode"

        echo '  "inbounds": ['
        generate_inbounds "$os"
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
        "utls": { "enabled": true, "fingerprint": "${fp}" },
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
        generate_route "$mode"

        echo '}'
    } > "$outfile"

    # 用 python3 格式化并验证 JSON
    if command -v python3 &> /dev/null; then
        if python3 -m json.tool "$outfile" > "$outfile.tmp" 2>/dev/null; then
            mv "$outfile.tmp" "$outfile"
        else
            rm -f "$outfile.tmp"
            log_warn "JSON 格式验证失败，请手动检查: $outfile"
        fi
    fi
}

# -----------------------------------------------------------------
# 生成全部客户端配置（5 OS × 2 路由模式 = 10 个文件）
# -----------------------------------------------------------------
ALL_OS_LIST=(ios macos android windows linux)
ALL_ROUTE_LIST=(global split)

log_step "生成全部 sing-box 客户端配置..."
for _os in "${ALL_OS_LIST[@]}"; do
    _fp=$(get_default_fp "$_os")
    # 用户选定的系统使用交互时选择的指纹，与 VLESS 分享链接保持一致
    [ "$_os" = "$CLIENT_OS" ] && _fp="$CLIENT_FINGERPRINT"
    for _mode in "${ALL_ROUTE_LIST[@]}"; do
        _outfile="${SINGBOX_CONFIG_DIR}/config_${_os}_${_mode}.json"
        generate_singbox_config "$_os" "$_mode" "$_fp" "$_outfile"
        log_info "  已生成: config_${_os}_${_mode}.json"
    done
done

# 当前会话选定的配置（供后续输出引用）
SINGBOX_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config_${CLIENT_OS}_${ROUTE_MODE}.json"
log_info "全部配置已保存至目录: ${SINGBOX_CONFIG_DIR}/"

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
echo -e "${DIM}              v${SCRIPT_VERSION}  (${SCRIPT_DATE})${NC}"
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
            echo -e "    ${GREEN}✓${NC} Apple   (apple.com, icloud.com, ...)"
            ;;
        ai+google)
            echo -e "    ${GREEN}✓${NC} ChatGPT (openai.com, chatgpt.com, ...)"
            echo -e "    ${GREEN}✓${NC} Claude  (anthropic.com, claude.ai, ...)"
            echo -e "    ${GREEN}✓${NC} Apple   (apple.com, icloud.com, ...)"
            echo -e "    ${GREEN}✓${NC} Google  (google.com, youtube.com, ...)"
            ;;
        ai+google+netflix)
            echo -e "    ${GREEN}✓${NC} ChatGPT (openai.com, chatgpt.com, ...)"
            echo -e "    ${GREEN}✓${NC} Claude  (anthropic.com, claude.ai, ...)"
            echo -e "    ${GREEN}✓${NC} Apple   (apple.com, icloud.com, ...)"
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

# ---- 5. 全部客户端配置文件列表 ----
echo -e "${BOLD}${MAGENTA}  ▶ 5. sing-box 客户端配置文件（全平台）${NC}"
echo -e "  ${DIM}目录: ${SINGBOX_CONFIG_DIR}/${NC}"
print_line
echo ""

_OS_LABELS=(
    "ios     → sing-box iOS / Stash / Shadowrocket"
    "macos   → sing-box macOS / V2rayU"
    "android → sing-box Android / NekoBox / v2rayNG"
    "windows → sing-box Windows / v2rayN / NekoRay"
    "linux   → sing-box CLI / 旁路由网关"
)
_ROUTE_LABELS=(
    "global  全局代理（所有流量走代理）"
    "split   分流模式（国内直连 / 国外代理）"
)

for _os in "${ALL_OS_LIST[@]}"; do
    # 找到对应的标签说明
    _label=""
    for _l in "${_OS_LABELS[@]}"; do
        if [[ "$_l" == "${_os}"* ]]; then _label="$_l"; break; fi
    done
    echo -e "  ${CYAN}${_label}${NC}"
    for _mode in "${ALL_ROUTE_LIST[@]}"; do
        _f="${SINGBOX_CONFIG_DIR}/config_${_os}_${_mode}.json"
        _size=$(wc -c < "$_f" 2>/dev/null || echo "?")
        printf "    ${GREEN}%-40s${NC}  ${DIM}%s bytes${NC}\n" "config_${_os}_${_mode}.json" "$_size"
        echo -e "    ${DIM}scp root@${SERVER_IP}:${_f} ./config_${_os}_${_mode}.json${NC}"
    done
    echo ""
done

echo -e "  ${YELLOW}一次性下载全部配置到本地当前目录:${NC}"
echo -e "  ${GREEN}scp -r root@${SERVER_IP}:${SINGBOX_CONFIG_DIR}/ ./sing-box-configs/${NC}"
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
        echo -e "  ${CYAN}TUN 入站 :${NC} 自动选择可用的 utun 虚拟网卡接管全局流量"
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
echo -e "  ${CYAN}下载全部配置   :${NC} ${GREEN}scp -r root@${SERVER_IP}:${SINGBOX_CONFIG_DIR}/ ./sing-box-configs/${NC}"
echo -e "  ${CYAN}下载单个配置   :${NC} ${GREEN}scp root@${SERVER_IP}:${SINGBOX_CONFIG_DIR}/config_<os>_<mode>.json ./${NC}"
echo -e "  ${CYAN}查看配置目录   :${NC} ${GREEN}ls -lh ${SINGBOX_CONFIG_DIR}/${NC}"
echo ""
print_dline
echo -e "${BOLD}${RED}  ⚠  请将以上所有信息保存好，私钥不会再次显示！${NC}"
print_dline
echo ""
