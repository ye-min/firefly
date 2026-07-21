#!/usr/bin/env bash

# 卸载 install.sh 安装的 Xray、Cloudflare WARP 和客户端配置。
#
# 注意：install.sh 和 install-cn.sh 共用同一个 Xray 服务与服务端配置。
# 运行本脚本会移除当前机器上的 Xray，无论它最后由哪个安装脚本配置。

set -uo pipefail

ASSUME_YES=0
DRY_RUN=0

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

usage() {
    cat <<'EOF'
用法：sudo bash uninstall.sh [选项]

选项：
  -y, --yes      不询问，直接卸载
      --dry-run  只显示将执行的操作，不修改系统
  -h, --help     显示帮助

本脚本将删除：
  - Xray 程序、systemd 服务、配置和日志
  - /root/sing-box-config
  - cloudflare-warp 软件包、warp-svc 服务、注册状态和软件源

本脚本不会删除：
  - /root/sing-box-cn-config
  - 系统依赖包
  - ufw/firewalld 或云厂商安全组规则
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知选项：$1"
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

require_root() {
    if (( EUID != 0 )); then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

run_cmd() {
    if (( DRY_RUN )); then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

remove_file() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        run_cmd rm -f -- "$path"
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] rm -f -- %q  # 当前不存在\n' "$path"
    fi
}

remove_directory() {
    local path=$1
    if [[ -d $path || -L $path ]]; then
        run_cmd rm -rf -- "$path"
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] rm -rf -- %q  # 当前不存在\n' "$path"
    fi
}

confirm_uninstall() {
    printf '%b将永久删除 Xray、WARP、服务端配置、密钥和原版客户端配置。%b\n' \
        "$BOLD$YELLOW" "$NC"
    log_warn "install.sh 与 install-cn.sh 共用 Xray；当前运行的任何 Xray 配置都会被删除。"
    log_info "/root/sing-box-cn-config 不会被删除。"

    if (( DRY_RUN || ASSUME_YES )); then
        return 0
    fi

    local answer
    read -r -p "输入 YES 确认卸载: " answer
    if [[ $answer != YES ]]; then
        log_info "已取消卸载"
        exit 0
    fi
}

stop_xray() {
    log_step "停止并禁用 Xray 服务"

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl disable --now xray.service || true
        run_cmd systemctl disable --now xray@.service || true
    else
        log_warn "未找到 systemctl，继续清理已知文件"
    fi
}

remove_xray_files() {
    log_step "删除 Xray 程序、服务、配置和日志"

    local files=(
        "/usr/local/bin/xray"
        "/etc/systemd/system/xray.service"
        "/etc/systemd/system/xray@.service"
        "/etc/systemd/system/multi-user.target.wants/xray.service"
        "/etc/logrotate.d/xray"
    )
    local directories=(
        "/usr/local/etc/xray"
        "/usr/local/share/xray"
        "/usr/local/lib/xray"
        "/var/log/xray"
        "/etc/systemd/system/xray.service.d"
        "/etc/systemd/system/xray@.service.d"
    )
    local path

    for path in "${files[@]}"; do
        remove_file "$path"
    done
    for path in "${directories[@]}"; do
        remove_directory "$path"
    done

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl daemon-reload
        run_cmd systemctl reset-failed xray.service || true
    fi
}

remove_original_client_configs() {
    log_step "删除原版 sing-box 客户端配置"
    remove_directory "/root/sing-box-config"
}

stop_warp() {
    log_step "停止 WARP 并删除注册状态"

    if command -v warp-cli >/dev/null 2>&1; then
        run_cmd warp-cli --accept-tos disconnect || true
        run_cmd warp-cli --accept-tos registration delete || true
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] warp-cli --accept-tos disconnect  # 当前未安装\n'
        printf '[DRY-RUN] warp-cli --accept-tos registration delete  # 当前未安装\n'
    fi

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl disable --now warp-svc.service || true
    fi
}

remove_warp_package() {
    log_step "卸载 Cloudflare WARP 软件包"
    local removed=0

    if command -v dpkg-query >/dev/null 2>&1 && \
       dpkg-query -W -f='${Status}' cloudflare-warp 2>/dev/null | grep -q 'install ok installed'; then
        if run_cmd apt-get purge -y cloudflare-warp; then
            removed=1
        else
            log_warn "apt-get 未能卸载 cloudflare-warp，继续清理已知文件"
        fi
    elif command -v rpm >/dev/null 2>&1 && rpm -q cloudflare-warp >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            run_cmd dnf remove -y cloudflare-warp || log_warn "dnf 未能卸载 cloudflare-warp"
        elif command -v yum >/dev/null 2>&1; then
            run_cmd yum remove -y cloudflare-warp || log_warn "yum 未能卸载 cloudflare-warp"
        fi
        removed=1
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] 卸载 cloudflare-warp 软件包  # 当前未检测到\n'
    fi

    if command -v rpm >/dev/null 2>&1 && rpm -q cloudflare-release >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1; then
            run_cmd dnf remove -y cloudflare-release || true
        elif command -v yum >/dev/null 2>&1; then
            run_cmd yum remove -y cloudflare-release || true
        fi
    fi

    (( removed == 1 )) && log_info "Cloudflare WARP 软件包卸载步骤已执行"
}

remove_warp_files() {
    log_step "清理 WARP 软件源和残留状态"

    local files=(
        "/etc/apt/sources.list.d/cloudflare-client.list"
        "/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
        "/etc/systemd/system/warp-svc.service"
    )
    local directories=(
        "/etc/cloudflare-warp"
        "/var/lib/cloudflare-warp"
        "/var/log/cloudflare-warp"
    )
    local path

    for path in "${files[@]}"; do
        remove_file "$path"
    done
    for path in "${directories[@]}"; do
        remove_directory "$path"
    done

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl daemon-reload
        run_cmd systemctl reset-failed warp-svc.service || true
    fi
}

verify_removal() {
    (( DRY_RUN )) && return 0

    hash -r
    if command -v xray >/dev/null 2>&1; then
        log_warn "PATH 中仍能找到 xray：$(command -v xray)；它可能由其他方式安装"
    else
        log_info "Xray 已移除"
    fi

    if command -v warp-cli >/dev/null 2>&1; then
        log_warn "PATH 中仍能找到 warp-cli：$(command -v warp-cli)"
    else
        log_info "Cloudflare WARP 已移除"
    fi
}

main() {
    parse_args "$@"
    require_root
    confirm_uninstall
    stop_xray
    remove_xray_files
    remove_original_client_configs
    stop_warp
    remove_warp_package
    remove_warp_files
    verify_removal

    printf '\n%b原版代理及 WARP 卸载完成。%b\n' "$BOLD$GREEN" "$NC"
    log_info "系统依赖和防火墙/安全组规则保持不变。"
    log_info "之后可以重新运行 install.sh 或 install-cn.sh 安装。"
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then
    main "$@"
fi
