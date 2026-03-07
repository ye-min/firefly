#!/bin/bash

# =============================================================
# Xray 一键部署脚本
# 协议: VLESS + Reality + XTLS Vision
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================
# 检查 root 权限
# =============================================================
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# =============================================================
# 交互式输入配置信息
# =============================================================
echo ""
echo "============================================="
echo "        Xray VLESS+Reality 一键部署"
echo "============================================="
echo ""
log_warn "以下信息将写入服务端配置，请准确填写"
echo ""

# UUID
while true; do
    read -p "请输入 UUID（直接回车自动生成）: " INPUT_UUID
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

# 端口
read -p "请输入监听端口（直接回车使用默认 443）: " INPUT_PORT
INPUT_PORT=${INPUT_PORT:-443}

# SNI
read -p "请输入 SNI 域名（直接回车使用默认 mirrors.aliyun.com）: " INPUT_SNI
INPUT_SNI=${INPUT_SNI:-mirrors.aliyun.com}

# Private Key
echo ""
log_info "即将生成 Reality 密钥对..."
echo ""

# =============================================================
# 安装 Xray
# =============================================================
log_info "开始安装 Xray..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
log_info "Xray 安装完成"

# 生成密钥对
KEYPAIR=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYPAIR" | grep PrivateKey | awk '{print $2}')
PUBLIC_KEY=$(echo "$KEYPAIR" | grep Password | awk '{print $2}')

# 生成 Short ID
SHORT_ID=$(openssl rand -hex 8)

echo ""
echo "============================================="
log_info "密钥对已生成，请妥善保存以下信息："
echo ""
echo "  UUID        : ${INPUT_UUID}"
echo "  Private Key : ${PRIVATE_KEY}"
echo "  Public Key  : ${PUBLIC_KEY}"
echo "  Short ID    : ${SHORT_ID}"
echo "  SNI         : ${INPUT_SNI}"
echo "  端口        : ${INPUT_PORT}"
echo "============================================="
echo ""

# =============================================================
# 写入 Xray 配置文件
# =============================================================
log_info "写入 Xray 配置文件..."

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

log_info "配置文件已写入 /usr/local/etc/xray/config.json"

# =============================================================
# 验证配置
# =============================================================
log_info "验证配置文件..."
if xray run -test -config /usr/local/etc/xray/config.json; then
    log_info "配置文件验证通过"
else
    log_error "配置文件验证失败，请检查"
    exit 1
fi

# =============================================================
# 防火墙放行端口
# =============================================================
log_info "配置防火墙..."
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
log_info "启动 Xray 服务..."
systemctl enable xray
systemctl restart xray

sleep 2

if systemctl is-active --quiet xray; then
    log_info "Xray 启动成功"
else
    log_error "Xray 启动失败，请查看日志: journalctl -u xray -f"
    exit 1
fi

# 确认端口监听
if ss -tlnp | grep -q ":${INPUT_PORT}"; then
    log_info "端口 ${INPUT_PORT} 监听正常"
else
    log_warn "端口 ${INPUT_PORT} 未检测到监听，请检查: ss -tlnp | grep ${INPUT_PORT}"
fi

# =============================================================
# 输出客户端配置
# =============================================================
echo ""
echo "============================================="
echo "           部署完成！客户端配置如下"
echo "============================================="
echo ""
echo "  协议        : VLESS"
echo "  服务器地址  : $(curl -s ifconfig.me 2>/dev/null || echo '请手动填入服务器IP')"
echo "  端口        : ${INPUT_PORT}"
echo "  UUID        : ${INPUT_UUID}"
echo "  Flow        : xtls-rprx-vision"
echo "  传输协议    : tcp"
echo "  TLS         : reality"
echo "  SNI         : ${INPUT_SNI}"
echo "  Public Key  : ${PUBLIC_KEY}"
echo "  Short ID    : ${SHORT_ID}"
echo "  指纹        : chrome"
echo ""
echo "  sing-box outbound 配置片段："
echo ""
cat << EOF
  {
    "type": "vless",
    "tag": "proxy",
    "server": "$(curl -s ifconfig.me 2>/dev/null || echo '你的服务器IP')",
    "server_port": ${INPUT_PORT},
    "uuid": "${INPUT_UUID}",
    "flow": "xtls-rprx-vision",
    "packet_encoding": "xudp",
    "tls": {
      "enabled": true,
      "server_name": "${INPUT_SNI}",
      "utls": { "enabled": true, "fingerprint": "chrome" },
      "reality": {
        "enabled": true,
        "public_key": "${PUBLIC_KEY}",
        "short_id": "${SHORT_ID}"
      }
    }
  }
EOF
echo ""
echo "============================================="
log_warn "请将以上客户端信息保存好，脚本不会再次显示密钥"
echo "============================================="
echo ""
