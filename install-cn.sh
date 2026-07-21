#!/usr/bin/env bash

# =============================================================================
# 中国大陆网站回国代理部署脚本
#
# 服务端：Xray VLESS + REALITY + XTLS Vision
# 客户端：sing-box 1.13.x
#
# 路由目标：
#   中国大陆域名/IP -> VLESS -> 中国大陆 VPS -> 目标网站
#   其他流量         -> 客户端本地直连
#
# 本脚本刻意不安装、不配置 Cloudflare WARP，以确保目标网站看到的是
# 中国大陆 VPS 的原始公网出口，而不是 Cloudflare 共享出口。
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.1"
SCRIPT_DATE="2026-07-21"

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
SINGBOX_CONFIG_DIR="/root/sing-box-cn-config"
XRAY_INSTALL_URL="${XRAY_INSTALL_URL:-}"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi

log_info()  { printf '%b[INFO]%b %s\n' "$GREEN" "$NC" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
log_step()  { printf '\n%b[STEP]%b %s\n' "$CYAN" "$NC" "$*"; }

die() {
    log_error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    log_error "脚本在第 ${line_no} 行失败（退出码 ${exit_code}）"
    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

require_root() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 权限运行此脚本"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

valid_port() {
    [[ $1 =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_uuid() {
    [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_hostname_or_ipv4() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ $value != *..* ]]
}

valid_fingerprint() {
    [[ $1 =~ ^(chrome|firefox|safari|edge)$ ]]
}

valid_client_os() {
    [[ $1 =~ ^(ios|macos|android|windows|linux)$ ]]
}

install_dependencies() {
    log_step "安装基础依赖"

    if command_exists apt-get; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates curl unzip openssl python3 iproute2
    elif command_exists dnf; then
        dnf install -y ca-certificates curl unzip openssl python3 iproute
    elif command_exists yum; then
        yum install -y ca-certificates curl unzip openssl python3 iproute
    else
        die "不支持当前包管理器；本脚本支持使用 systemd 的 Debian、Ubuntu、Fedora、RHEL、Rocky Linux 和 AlmaLinux"
    fi
}

generate_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr 'A-F' 'a-f' </proc/sys/kernel/random/uuid
    elif command_exists uuidgen; then
        uuidgen | tr 'A-F' 'a-f'
    else
        die "无法自动生成 UUID，请通过 CN_UUID 环境变量提供"
    fi
}

detect_public_ipv4() {
    local url candidate
    local urls=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.me/ip"
        "https://api-ipv4.ip.sb/ip"
    )

    for url in "${urls[@]}"; do
        candidate=$(curl -4fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null || true)
        candidate=${candidate//$'\r'/}
        candidate=${candidate//$'\n'/}
        if [[ $candidate =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

prompt_with_default() {
    local prompt=$1
    local default_value=$2
    local result
    read -r -p "${prompt} [${default_value}]: " result
    printf '%s\n' "${result:-$default_value}"
}

collect_configuration() {
    printf '\n%b中国大陆网站回国代理部署脚本%b\n' "$BOLD" "$NC"
    printf '版本 %s（%s）\n\n' "$SCRIPT_VERSION" "$SCRIPT_DATE"

    INPUT_UUID=${CN_UUID:-}
    if [[ -z $INPUT_UUID ]]; then
        INPUT_UUID=$(generate_uuid)
        INPUT_UUID=$(prompt_with_default "UUID" "$INPUT_UUID")
    fi
    valid_uuid "$INPUT_UUID" || die "UUID 格式不正确"
    INPUT_UUID=$(printf '%s' "$INPUT_UUID" | tr 'A-F' 'a-f')

    INPUT_PORT=${CN_PORT:-}
    if [[ -z $INPUT_PORT ]]; then
        INPUT_PORT=$(prompt_with_default "Xray 监听端口" "443")
    fi
    valid_port "$INPUT_PORT" || die "端口必须在 1-65535 之间"

    INPUT_SNI=${CN_REALITY_SERVER_NAME:-}
    if [[ -z $INPUT_SNI ]]; then
        INPUT_SNI=$(prompt_with_default "REALITY 目标域名/SNI" "www.microsoft.com")
    fi
    valid_hostname_or_ipv4 "$INPUT_SNI" || die "REALITY 目标域名格式不正确"

    SERVER_ADDRESS=${CN_SERVER_ADDRESS:-}
    if [[ -z $SERVER_ADDRESS ]]; then
        local detected_ip=""
        detected_ip=$(detect_public_ipv4 || true)
        if [[ -n $detected_ip ]]; then
            SERVER_ADDRESS=$(prompt_with_default "客户端连接的服务器公网 IP 或域名" "$detected_ip")
        else
            read -r -p "客户端连接的服务器公网 IP 或域名: " SERVER_ADDRESS
        fi
    fi
    valid_hostname_or_ipv4 "$SERVER_ADDRESS" || die "服务器地址格式不正确"

    CLIENT_OS=${CN_CLIENT_OS:-}
    if [[ -z $CLIENT_OS ]]; then
        printf '\n客户端系统：1) iOS  2) macOS  3) Android  4) Windows  5) Linux\n'
        local os_choice
        read -r -p "请选择 [1-5，默认 2]: " os_choice
        case "${os_choice:-2}" in
            1) CLIENT_OS="ios" ;;
            2) CLIENT_OS="macos" ;;
            3) CLIENT_OS="android" ;;
            4) CLIENT_OS="windows" ;;
            5) CLIENT_OS="linux" ;;
            *) die "客户端系统选项无效" ;;
        esac
    fi
    valid_client_os "$CLIENT_OS" || die "CN_CLIENT_OS 必须是 ios、macos、android、windows 或 linux"

    CLIENT_FINGERPRINT=${CN_FINGERPRINT:-}
    if [[ -z $CLIENT_FINGERPRINT ]]; then
        case "$CLIENT_OS" in
            ios) CLIENT_FINGERPRINT="safari" ;;
            linux) CLIENT_FINGERPRINT="firefox" ;;
            *) CLIENT_FINGERPRINT="chrome" ;;
        esac
        CLIENT_FINGERPRINT=$(prompt_with_default "uTLS 指纹（chrome/firefox/safari/edge）" "$CLIENT_FINGERPRINT")
    fi
    valid_fingerprint "$CLIENT_FINGERPRINT" || die "不支持的 uTLS 指纹"

    printf '\n%b配置摘要%b\n' "$BOLD" "$NC"
    printf '  服务器地址 : %s\n' "$SERVER_ADDRESS"
    printf '  监听端口   : %s\n' "$INPUT_PORT"
    printf '  UUID       : %s\n' "$INPUT_UUID"
    printf '  REALITY SNI: %s\n' "$INPUT_SNI"
    printf '  客户端系统 : %s\n' "$CLIENT_OS"
    printf '  uTLS 指纹  : %s\n' "$CLIENT_FINGERPRINT"
    printf '  WARP       : 禁用（固定使用大陆 VPS 原始出口）\n\n'

    if [[ ${CN_ASSUME_YES:-0} != 1 ]]; then
        local confirm
        read -r -p "确认部署？[Y/n]: " confirm
        [[ ${confirm:-Y} =~ ^[Yy]$ ]] || die "部署已取消"
    fi
}

verify_xray_installer() {
    local installer=$1
    [[ -s $installer ]] || return 1
    bash -n "$installer" >/dev/null 2>&1 || return 1
    grep -q 'XTLS/Xray-install' "$installer"
}

download_xray_installer() {
    local destination=$1
    local source_file=${CN_XRAY_INSTALLER_FILE:-}
    local proxy=${CN_XRAY_PROXY:-}
    local url
    local urls=()
    # 与 install.sh 使用相同的 curl 网络行为：不设置连接或总下载时限。
    # 大陆网络连接 GitHub 可能很慢，过短的超时会误判为下载失败。
    local curl_args=(-fsSL)

    if [[ -n $source_file ]]; then
        [[ -f $source_file ]] || {
            log_error "CN_XRAY_INSTALLER_FILE 不存在：${source_file}"
            return 1
        }
        cp "$source_file" "$destination"
        verify_xray_installer "$destination" || {
            log_error "本地 Xray 安装器无效或 Bash 语法不正确：${source_file}"
            return 1
        }
        log_info "使用本地 Xray 官方安装器：${source_file}"
        return 0
    fi

    [[ -n $XRAY_INSTALL_URL ]] && urls+=("$XRAY_INSTALL_URL")
    urls+=(
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
        "https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
    )
    [[ -n $proxy ]] && curl_args+=(--proxy "$proxy")

    for url in "${urls[@]}"; do
        log_info "尝试下载 Xray 官方安装器：${url}"
        if curl "${curl_args[@]}" "$url" -o "$destination"; then
            if verify_xray_installer "$destination"; then
                log_info "Xray 官方安装器下载成功"
                return 0
            fi
            log_warn "下载内容不是有效的 Xray 官方安装器，尝试下一个地址"
        else
            log_warn "下载失败，尝试下一个官方地址"
        fi
        : >"$destination"
    done

    return 1
}

verify_local_xray_archive() {
    local archive=$1
    local digest_file=${CN_XRAY_LOCAL_DGST:-${archive}.dgst}
    local expected_sha=${CN_XRAY_LOCAL_SHA256:-}
    local actual_sha expected_sha_normalized

    [[ -f $archive ]] || die "CN_XRAY_LOCAL_ZIP 不存在：${archive}"
    unzip -tq "$archive" >/dev/null || die "本地 Xray ZIP 已损坏：${archive}"

    if [[ -f $digest_file ]]; then
        expected_sha=$(awk -F '= ' '/256=/ {print $2; exit}' "$digest_file")
        [[ -n $expected_sha ]] || die "无法从校验文件读取 SHA-256：${digest_file}"
    fi

    [[ $expected_sha =~ ^[0-9a-fA-F]{64}$ ]] || die \
        "离线安装必须提供官方校验文件 ${archive}.dgst，或设置 CN_XRAY_LOCAL_SHA256"

    command_exists sha256sum || die "找不到 sha256sum，无法校验本地 Xray ZIP"
    actual_sha=$(sha256sum "$archive" | awk '{print $1}' | tr 'A-F' 'a-f')
    expected_sha_normalized=$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')
    [[ $actual_sha == "$expected_sha_normalized" ]] || die "本地 Xray ZIP 的 SHA-256 校验失败"
    log_info "本地 Xray ZIP 的 SHA-256 校验通过"
}

install_xray() {
    log_step "安装或更新 Xray"

    if command_exists xray && [[ -f /etc/systemd/system/xray.service ]] && \
       [[ ${CN_FORCE_XRAY_UPDATE:-0} != 1 ]] && [[ -z ${CN_XRAY_LOCAL_ZIP:-} ]]; then
        local installed_version
        installed_version=$(xray version)
        log_info "已安装 ${installed_version%%$'\n'*}，跳过联网更新"
        log_info "如需强制更新，请设置 CN_FORCE_XRAY_UPDATE=1"
        return 0
    fi

    local installer
    local local_archive=${CN_XRAY_LOCAL_ZIP:-}
    local proxy=${CN_XRAY_PROXY:-}
    local install_status=0
    installer=$(mktemp /tmp/install-cn-xray.XXXXXX.sh)

    if ! download_xray_installer "$installer"; then
        rm -f "$installer"
        log_error "无法从 Xray 官方 GitHub 地址下载安装器（curl 退出码 28 表示超时）"
        log_error "可以在美国电脑下载官方安装器和 Xray ZIP，再 scp 到服务器进行离线安装。"
        log_error "重新运行时设置：CN_XRAY_INSTALLER_FILE、CN_XRAY_LOCAL_ZIP，并提供同名 .dgst 文件。"
        return 1
    fi

    if [[ -n $local_archive ]]; then
        verify_local_xray_archive "$local_archive"
        bash "$installer" install --local "$local_archive" || install_status=$?
    elif [[ -n $proxy ]]; then
        bash "$installer" install --proxy "$proxy" || install_status=$?
    else
        bash "$installer" install || install_status=$?
    fi
    rm -f "$installer"

    if (( install_status != 0 )); then
        log_error "Xray 官方安装器执行失败（退出码 ${install_status}）"
        if [[ -z $proxy && -z $local_archive ]]; then
            log_error "安装器仍需访问 api.github.com 和 GitHub Releases。"
            log_error "请设置 CN_XRAY_PROXY，或使用 CN_XRAY_LOCAL_ZIP 离线安装。"
        fi
        return "$install_status"
    fi

    command_exists xray || die "Xray 安装完成后仍找不到 xray 命令"
    local xray_version
    xray_version=$(xray version)
    log_info "${xray_version%%$'\n'*}"
}

generate_reality_keys() {
    log_step "生成 REALITY 密钥"
    local keypair
    keypair=$(xray x25519)

    PRIVATE_KEY=$(awk -F':[[:space:]]*' '
        tolower($1) ~ /private/ { print $2; exit }
    ' <<<"$keypair")

    PUBLIC_KEY=$(awk -F':[[:space:]]*' '
        tolower($1) ~ /public|password/ { print $2; exit }
    ' <<<"$keypair")

    [[ -n $PRIVATE_KEY && -n $PUBLIC_KEY ]] || {
        log_error "无法解析 xray x25519 输出："
        printf '%s\n' "$keypair" >&2
        return 1
    }

    SHORT_ID=$(openssl rand -hex 8)
    log_info "REALITY 密钥和 Short ID 已生成"
}

check_reality_target() {
    log_step "检查 REALITY 目标"
    if xray tls ping "$INPUT_SNI" >/tmp/install-cn-reality-check.log 2>&1; then
        log_info "REALITY 目标 ${INPUT_SNI}:443 可连接"
    else
        log_warn "xray tls ping 未能确认 ${INPUT_SNI}:443 可用"
        log_warn "检查结果保存在 /tmp/install-cn-reality-check.log"
        log_warn "如果客户端发生 REALITY 握手失败，请更换 CN_REALITY_SERVER_NAME 后重新运行脚本"
    fi
}

write_xray_config() {
    log_step "写入 Xray 服务端配置"
    mkdir -p "$XRAY_CONFIG_DIR"

    if [[ -f $XRAY_CONFIG_FILE ]]; then
        local backup_file
        backup_file="${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$XRAY_CONFIG_FILE" "$backup_file"
        log_info "旧配置已备份到 ${backup_file}"
    fi

    local temp_config
    temp_config=$(mktemp /tmp/install-cn-xray-config.XXXXXX.json)
    cat >"$temp_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
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
          "target": "${INPUT_SNI}:443",
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
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
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

    xray run -test -config "$temp_config"
    install -m 0644 "$temp_config" "$XRAY_CONFIG_FILE"
    rm -f "$temp_config"
    log_info "Xray 配置验证通过：${XRAY_CONFIG_FILE}"
}

configure_firewall() {
    log_step "检查服务器防火墙"

    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${INPUT_PORT}/tcp"
        log_info "ufw 已放行 TCP ${INPUT_PORT}"
    elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${INPUT_PORT}/tcp"
        firewall-cmd --reload
        log_info "firewalld 已放行 TCP ${INPUT_PORT}"
    else
        log_warn "未发现正在运行的 ufw/firewalld；未修改系统防火墙"
    fi

    log_warn "请同时在云厂商安全组中放行 TCP ${INPUT_PORT}"
}

start_xray() {
    log_step "启动 Xray"
    systemctl enable xray >/dev/null
    systemctl restart xray

    if ! systemctl is-active --quiet xray; then
        journalctl -u xray -n 80 --no-pager || true
        die "Xray 启动失败"
    fi

    if ss -ltnp | grep -q ":${INPUT_PORT}[[:space:]]"; then
        log_info "Xray 已监听 TCP ${INPUT_PORT}"
    else
        log_warn "未在 ss 输出中确认端口 ${INPUT_PORT}，请运行：ss -ltnp"
    fi
}

default_fingerprint_for_os() {
    case "$1" in
        ios) echo "safari" ;;
        linux) echo "firefox" ;;
        *) echo "chrome" ;;
    esac
}

generate_inbounds() {
    local os=$1
    case "$os" in
        ios|android)
            cat <<'EOF'
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
            cat <<'EOF'
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
        windows|linux)
            cat <<'EOF'
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
    esac
}

generate_singbox_config() {
    local os=$1
    local fingerprint=$2
    local output_file=$3

    {
        cat <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-direct"
      },
      {
        "type": "udp",
        "tag": "dns-cn",
        "server": "223.5.5.5",
        "server_port": 53,
        "detour": "proxy"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-cn",
        "action": "route",
        "server": "dns-cn"
      }
    ],
    "final": "dns-direct",
    "strategy": "ipv4_only"
  },
  "inbounds": [
EOF
        generate_inbounds "$os"
        cat <<EOF
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_ADDRESS}",
      "server_port": ${INPUT_PORT},
      "uuid": "${INPUT_UUID}",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "tls": {
        "enabled": true,
        "server_name": "${INPUT_SNI}",
        "utls": {
          "enabled": true,
          "fingerprint": "${fingerprint}"
        },
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      },
      {
        "rule_set": ["geoip-cn", "geosite-cn"],
        "action": "route",
        "outbound": "proxy"
      }
    ],
    "rule_set": [
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geoip/cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs",
        "download_detour": "direct"
      }
    ],
    "final": "direct",
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct"
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF
    } >"$output_file"

    python3 -m json.tool "$output_file" >"${output_file}.formatted"
    mv "${output_file}.formatted" "$output_file"
}

write_singbox_configs() {
    log_step "生成 sing-box 1.13.x 客户端配置"
    mkdir -p "$SINGBOX_CONFIG_DIR"

    local os fingerprint output_file
    for os in ios macos android windows linux; do
        fingerprint=$(default_fingerprint_for_os "$os")
        if [[ $os == "$CLIENT_OS" ]]; then
            fingerprint=$CLIENT_FINGERPRINT
        fi
        output_file="${SINGBOX_CONFIG_DIR}/config_${os}_cn.json"
        generate_singbox_config "$os" "$fingerprint" "$output_file"
        chmod 0600 "$output_file"
        log_info "已生成 ${output_file}"
    done

    SELECTED_CONFIG_FILE="${SINGBOX_CONFIG_DIR}/config_${CLIENT_OS}_cn.json"
}

print_summary() {
    local vless_link
    vless_link="vless://${INPUT_UUID}@${SERVER_ADDRESS}:${INPUT_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${INPUT_SNI}&fp=${CLIENT_FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#CN-Reality"

    printf '\n%b部署完成%b\n' "$BOLD$GREEN" "$NC"
    printf '  Xray 服务端配置 : %s\n' "$XRAY_CONFIG_FILE"
    printf '  sing-box 配置    : %s\n' "$SELECTED_CONFIG_FILE"
    printf '  客户端要求       : sing-box 1.13.x\n'
    printf '  WARP             : 未配置、未使用\n'
    printf '  路由             : 中国大陆 -> proxy；其他 -> direct\n'
    printf '  中国 DNS         : 223.5.5.5，经大陆 VPS 查询\n\n'

    printf '%bVLESS 分享链接（仅节点参数，不包含回国分流规则）%b\n%s\n\n' \
        "$BOLD" "$NC" "$vless_link"
    printf '下载当前客户端配置：\n'
    printf '  scp root@%s:%s ./config_%s_cn.json\n\n' \
        "$SERVER_ADDRESS" "$SELECTED_CONFIG_FILE" "$CLIENT_OS"

    printf '验证命令：\n'
    printf '  服务端：systemctl status xray --no-pager\n'
    printf '  客户端：sing-box check -c config_%s_cn.json\n' "$CLIENT_OS"
    printf '  出口测试：打开中国网站或访问 https://myip.ipip.net\n\n'
    printf '%b注意：%b如果大陆网站本身拒绝数据中心 IP，即使 IP 位于大陆也可能无法访问。\n' \
        "$YELLOW" "$NC"
}

main() {
    require_root
    command_exists systemctl || die "本脚本仅支持使用 systemd 的 Linux 发行版"
    install_dependencies
    collect_configuration
    install_xray
    generate_reality_keys
    check_reality_target
    write_xray_config
    configure_firewall
    start_xray
    write_singbox_configs
    print_summary
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then
    main "$@"
fi
