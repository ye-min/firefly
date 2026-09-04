#!/usr/bin/env bash

# 卸载 install.sh 安装的 Xray、Cloudflare WARP 和客户端配置。
#
# 注意：install.sh 和 install-cn.sh 共用同一个 Xray 服务与服务端配置。
# 运行本脚本会移除当前机器上的 Xray，无论它最后由哪个安装脚本配置。

set -uo pipefail

ASSUME_YES=0
DRY_RUN=0
REMOVAL_PATHS=()
XRAY_UNITS=()

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
    REMOVAL_PATHS+=("$path")
    if [[ -e $path || -L $path ]]; then
        run_cmd rm -f -- "$path"
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] rm -f -- %q  # 当前不存在\n' "$path"
    fi
}

remove_directory() {
    local path=$1
    REMOVAL_PATHS+=("$path")
    if [[ -e $path || -L $path ]]; then
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

    local answer=""
    read -r -p "输入 YES 确认卸载: " answer || answer=""
    if [[ $answer != YES ]]; then
        log_info "已取消卸载"
        exit 0
    fi
}

# 不对不存在的服务执行 stop；通信失败必须显式报错。
stop_service() {
    local unit=$1 state
    state=$(systemctl show "$unit" --property=LoadState --value) || return 1
    if [[ $state == not-found ]]; then
        return 0
    fi
    [[ -n $state ]] || return 1
    run_cmd systemctl stop "$unit" || return 1
    run_cmd systemctl disable "$unit" || return 1
    run_cmd systemctl reset-failed "$unit" || return 1
}

stop_xray() {
    log_step "停止并禁用 Xray 服务及实例"
    local units files unit
    units=$(systemctl list-units --all --plain --no-legend 'xray@*.service') || return 1
    files=$(systemctl list-unit-files --no-legend 'xray@*.service') || return 1
    XRAY_UNITS=("xray.service")
    while read -r unit _; do
        if [[ $unit == xray@*.service && $unit != xray@.service ]]; then
            XRAY_UNITS+=("$unit")
        fi
    done <<< "$(printf '%s\n%s\n' "$units" "$files" | sort -u)"
    for unit in ${XRAY_UNITS[@]+"${XRAY_UNITS[@]}"}; do
        stop_service "$unit" || return 1
    done
    # 官方安装器可能创建此定时任务。
    stop_service logrotate@xray.timer || return 1
    stop_service logrotate@xray.service || return 1
    if (( ! DRY_RUN )) && pgrep -x xray >/dev/null; then
        log_error "仍有 Xray 进程运行，请先停止手动启动或其他管理器启动的实例"
        return 1
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
        remove_file "$path" || return 1
    done
    for path in "${directories[@]}"; do
        remove_directory "$path" || return 1
    done

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl daemon-reload || return 1
    fi
}

remove_original_client_configs() {
    log_step "删除原版 sing-box 客户端配置"
    remove_directory "/root/sing-box-config"
}

stop_warp() {
    log_step "停止 WARP 并删除注册状态"

    if command -v warp-cli >/dev/null 2>&1; then
        run_cmd warp-cli --accept-tos disconnect || log_warn "WARP 断开命令失败，将继续停止服务"
        run_cmd warp-cli --accept-tos registration delete || log_warn "未能通过 WARP 守护进程删除注册；服务停止后将清理本地注册状态"
    elif (( DRY_RUN )); then
        printf '[DRY-RUN] warp-cli --accept-tos disconnect  # 当前未安装\n'
        printf '[DRY-RUN] warp-cli --accept-tos registration delete  # 当前未安装\n'
    fi

    if command -v systemctl >/dev/null 2>&1; then
        stop_service warp-svc.service || return 1
    fi
    if (( ! DRY_RUN )) && pgrep -x warp-svc >/dev/null; then
        log_error "仍有 warp-svc 进程运行，停止清理以免运行中的服务重写注册状态"
        return 1
    fi
}

# config-files、半安装等状态也需要 purge。
deb_package_present() {
    local status
    status=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1
    [[ -n $status && $status != *" not-installed" ]]
}

remove_warp_package() {
    log_step "卸载 Cloudflare WARP 软件包"
    local package manager
    if command -v dpkg-query >/dev/null 2>&1; then
        if deb_package_present cloudflare-warp; then
            run_cmd apt-get purge -y cloudflare-warp || return 1
        fi
    elif command -v rpm >/dev/null 2>&1; then
        for package in cloudflare-warp cloudflare-release; do
            if rpm -q "$package" >/dev/null 2>&1; then
                if command -v dnf >/dev/null 2>&1; then
                    manager=dnf
                elif command -v yum >/dev/null 2>&1; then
                    manager=yum
                else
                    log_error "检测到 $package，但找不到 dnf/yum，无法卸载"
                    return 1
                fi
                run_cmd "$manager" remove -y "$package" || return 1
            fi
        done
    fi
    return 0
}

remove_warp_files() {
    log_step "清理 WARP 软件源和残留状态"

    local files=(
        "/etc/apt/sources.list.d/cloudflare-client.list"
        "/etc/yum.repos.d/cloudflare-warp.repo"
        "/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"
        "/etc/systemd/system/warp-svc.service"
        "/etc/systemd/system/multi-user.target.wants/warp-svc.service"
    )
    local directories=(
        "/etc/systemd/system/warp-svc.service.d"
        "/etc/cloudflare-warp"
        "/var/lib/cloudflare-warp"
        "/var/log/cloudflare-warp"
    )
    local path

    for path in "${files[@]}"; do
        remove_file "$path" || return 1
    done
    for path in "${directories[@]}"; do
        remove_directory "$path" || return 1
    done

    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl daemon-reload || return 1
    fi
}

verify_removal() {
    (( DRY_RUN )) && return 0
    local failed=0 name path state
    hash -r
    for name in xray warp-cli warp-svc; do
        if command -v "$name" >/dev/null 2>&1; then
            log_error "仍能找到程序: $(command -v "$name")；请检查是否由其他方式安装"
            failed=1
        fi
    done
    for path in ${REMOVAL_PATHS[@]+"${REMOVAL_PATHS[@]}"}; do
        if [[ -e $path || -L $path ]]; then
            log_error "残留文件或目录: $path"
            failed=1
        fi
    done
    for name in ${XRAY_UNITS[@]+"${XRAY_UNITS[@]}"} xray@.service warp-svc.service; do
        state=$(systemctl show "$name" --property=LoadState --value) || return 1
        if [[ $state != not-found ]]; then
            log_error "服务仍存在或无法确认已移除: $name ($state)"
            failed=1
        fi
    done
    if command -v dpkg-query >/dev/null 2>&1 && deb_package_present cloudflare-warp; then
        log_error "cloudflare-warp 软件包或包配置仍存在"
        failed=1
    fi
    if command -v rpm >/dev/null 2>&1; then
        for name in cloudflare-warp cloudflare-release; do
            if rpm -q "$name" >/dev/null 2>&1; then
                log_error "软件包仍存在: $name"
                failed=1
            fi
        done
    fi
    return "$failed"
}

main() {
    parse_args "$@"
    require_root
    confirm_uninstall
    # 安装脚本要求 systemd；无法管理服务时不冒险删除运行中的文件。
    if ! command -v systemctl >/dev/null 2>&1 || ! command -v pgrep >/dev/null 2>&1; then
        log_error "需要 systemctl 和 pgrep，无法安全确认服务已经停止"
        return 1
    fi
    local step
    for step in stop_xray stop_warp remove_xray_files remove_original_client_configs \
        remove_warp_package remove_warp_files verify_removal; do
        if ! "$step"; then
            log_error "卸载未完成（步骤: ${step}）。请解决上述错误后重新运行 uninstall.sh。"
            return 1
        fi
    done
    if (( DRY_RUN )); then
        log_info "预演完成，未修改系统，也未执行实际卸载验证。"
        return 0
    fi

    printf '\n%b原版代理及 WARP 卸载完成。%b\n' "$BOLD$GREEN" "$NC"
    log_info "系统依赖和防火墙/安全组规则保持不变。"
    log_info "之后可以重新运行 install.sh 或 install-cn.sh 安装。"
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then
    main "$@"
fi
