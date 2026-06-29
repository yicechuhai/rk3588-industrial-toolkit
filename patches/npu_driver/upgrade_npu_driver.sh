#!/bin/bash
#===============================================================================
# upgrade_npu_driver.sh — RK3588 NPU Driver & RKNN Runtime Auto Upgrader
# 功能：自动检测并升级 NPU 驱动和 RKNN Runtime，失败时自动回滚
# 兼容：NanoPC T6 / 鲁班猫8 / Radxa Rock 5B / Orange Pi 5 / 飞凌 OK3588
# 依赖：curl, wget, dpkg, tar
#===============================================================================

set -e

VERSION="v1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 备份目录
BACKUP_DIR="/opt/rk3588-toolkit/backups/npu_$(date +%Y%m%d_%H%M%S)"
ROLLBACK_NEEDED=false
BACKUP_COMPLETED=false

# RKNN Runtime 下载地址（官方 GitHub Release）
# 当有新版本时更新此 URL
RKNN_RUNTIME_URL="https://github.com/airockchip/rknn-toolkit2/releases/download/v2.3.2/rknn_runtime_2.3.2_linux_aarch64.deb"
RKNN_RUNTIME_DEB="/tmp/rknn_runtime_2.3.2_linux_aarch64.deb"

# NPU 驱动源码（内核补丁）地址
NPU_DRIVER_URL="https://github.com/airockchip/rknn-llm/raw/refs/heads/main/rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2"
NPU_DRIVER_TAR="/tmp/rknpu_driver_0.9.8.tar.bz2"

#===============================================================================
# 辅助函数
#===============================================================================
print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "  RK3588 NPU Driver & Runtime"
    echo "  Auto Upgrader ${VERSION}"
    echo "============================================"
    echo -e "${NC}"
}

log_info()  { echo -e "  ${GREEN}INFO${NC}  $(date '+%H:%M:%S')  $*"; }
log_warn()  { echo -e "  ${YELLOW}WARN${NC}  $(date '+%H:%M:%S')  $*"; }
log_error() { echo -e "  ${RED}ERROR${NC} $(date '+%H:%M:%S')  $*" >&2; }

cleanup() {
    # 如果脚本被中断，执行回滚
    if [ "$ROLLBACK_NEEDED" = true ] && [ "$BACKUP_COMPLETED" = true ]; then
        echo ""
        log_warn "脚本被中断，正在回滚..."
        do_rollback
    fi
    # 清理临时文件
    rm -f "$RKNN_RUNTIME_DEB" "$NPU_DRIVER_TAR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

usage() {
    echo "用法: sudo bash upgrade_npu_driver.sh [选项]"
    echo ""
    echo "选项:"
    echo "  --runtime-only    仅升级 RKNN Runtime，不碰内核驱动"
    echo "  --force           跳过版本检查，强制升级到最新版"
    echo "  --dry-run         仅检查当前状态和可升级版本，不执行实际操作"
    echo "  --help, -h        显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  sudo bash upgrade_npu_driver.sh               # 自动检测并升级"
    echo "  sudo bash upgrade_npu_driver.sh --runtime-only # 仅升级 Runtime"
    echo "  sudo bash upgrade_npu_driver.sh --dry-run     # 仅检查"
}

#===============================================================================
# 版本比较
#===============================================================================
version_compare() {
    if [ "$1" = "$2" ]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]}; i++)); do
        if [ -z "${ver2[$i]}" ]; then
            ver2[$i]=0
        fi
        if ((10#${ver1[$i]} > 10#${ver2[$i]})); then
            return 1
        fi
        if ((10#${ver1[$i]} < 10#${ver2[$i]})); then
            return 2
        fi
    done
    return 0
}

#===============================================================================
# 检测当前版本
#===============================================================================
get_current_versions() {
    local driver_ver=""
    local runtime_ver=""

    # NPU 驱动版本
    if [ -f /sys/kernel/debug/rknpu/version ]; then
        driver_ver=$(cat /sys/kernel/debug/rknpu/version 2>/dev/null | head -1 | sed 's/^v//')
    fi

    # RKNN Runtime 版本
    local runtime_path=""
    for libpath in /usr/lib/librknnrt.so /usr/lib64/librknnrt.so /usr/local/lib/librknnrt.so; do
        if [ -f "$libpath" ]; then
            runtime_path="$libpath"
            break
        fi
    done
    if [ -z "$runtime_path" ]; then
        runtime_path=$(ldconfig -p 2>/dev/null | grep "librknnrt.so" | awk '{print $NF}' | head -1 || true)
    fi
    if [ -n "$runtime_path" ] && [ -f "$runtime_path" ]; then
        runtime_ver=$(strings "$runtime_path" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi

    echo "$driver_ver|$runtime_ver"
}

#===============================================================================
# 备份当前状态
#===============================================================================
do_backup() {
    echo ""
    echo -e "${CYAN}━━━ 1. 备份当前 NPU 状态 ━━━${NC}"

    mkdir -p "$BACKUP_DIR"
    log_info "备份目录: ${BACKUP_DIR}"

    # 记录当前版本
    {
        echo "# NPU Backup - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "KERNEL: $(uname -r)"
        echo "DRIVER: $(cat /sys/kernel/debug/rknpu/version 2>/dev/null || echo 'unknown')"
        echo "ARCH: $(uname -m)"
    } > "$BACKUP_DIR/version_info.txt"
    log_info "版本信息已保存"

    # 备份 librknnrt.so
    local lib_backed_up=false
    for libpath in /usr/lib/librknnrt.so /usr/lib64/librknnrt.so; do
        if [ -f "$libpath" ]; then
            cp "$libpath" "$BACKUP_DIR/"
            # 同时备份符号链接目标
            local real_path=$(readlink -f "$libpath" 2>/dev/null || echo "$libpath")
            if [ "$real_path" != "$libpath" ] && [ -f "$real_path" ]; then
                cp "$real_path" "$BACKUP_DIR/"
            fi
            lib_backed_up=true
            log_info "已备份: ${libpath}"
        fi
    done

    if [ "$lib_backed_up" = false ]; then
        log_warn "未找到 librknnrt.so 需要备份"
    fi

    # 备份 rknn_server
    if [ -f /usr/bin/rknn_server ]; then
        cp /usr/bin/rknn_server "$BACKUP_DIR/"
        log_info "已备份: rknn_server"
    fi

    BACKUP_COMPLETED=true
    ROLLBACK_NEEDED=true
    log_info "备份完成 (${BACKUP_DIR})"
}

#===============================================================================
# 安装 RKNN Runtime
#===============================================================================
install_runtime() {
    echo ""
    echo -e "${CYAN}━━━ 2. 安装/升级 RKNN Runtime ━━━${NC}"

    # 下载 deb 包
    if [ ! -f "$RKNN_RUNTIME_DEB" ]; then
        log_info "下载 RKNN Runtime 2.3.2..."
        if wget -q --show-progress "$RKNN_RUNTIME_URL" -O "$RKNN_RUNTIME_DEB"; then
            log_info "下载完成"
        else
            log_error "下载失败: ${RKNN_RUNTIME_URL}"
            log_error "请检查网络连接或手动下载后重试"
            return 1
        fi
    fi

    # 验证 deb 包
    if ! dpkg-deb -I "$RKNN_RUNTIME_DEB" > /dev/null 2>&1; then
        log_error "下载的文件不是有效的 deb 包"
        rm -f "$RKNN_RUNTIME_DEB"
        return 1
    fi

    # 停止 rknn_server（如果运行中）
    if pgrep -x "rknn_server" > /dev/null 2>&1; then
        log_info "停止 rknn_server..."
        killall rknn_server 2>/dev/null || true
        sleep 1
    fi

    # 安装
    log_info "安装 RKNN Runtime..."
    if dpkg -i "$RKNN_RUNTIME_DEB" 2>&1 | tail -5; then
        log_info "RKNN Runtime 安装成功"
        # 修复可能的依赖问题
        apt-get install -f -y 2>/dev/null || true
    else
        log_error "RKNN Runtime 安装失败"
        return 1
    fi

    # 验证安装
    local verify_path=""
    for libpath in /usr/lib/librknnrt.so /usr/lib64/librknnrt.so /usr/local/lib/librknnrt.so; do
        if [ -f "$libpath" ]; then
            verify_path="$libpath"
            break
        fi
    done

    if [ -n "$verify_path" ]; then
        local new_ver=$(strings "$verify_path" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        log_info "RKNN Runtime 已安装: ${verify_path} (${new_ver})"
        return 0
    else
        log_error "安装后未找到 librknnrt.so"
        return 1
    fi
}

#===============================================================================
# 安装/升级 NPU 内核驱动
#===============================================================================
install_npu_driver() {
    echo ""
    echo -e "${CYAN}━━━ 3. 升级 NPU 内核驱动 ━━━${NC}"

    local kernel_src_dir="/usr/src/kernel-$(uname -r)"
    local kernel_build_dir=""

    # 检测内核源码位置
    if [ -d "/lib/modules/$(uname -r)/build" ]; then
        kernel_build_dir="/lib/modules/$(uname -r)/build"
    elif [ -d "/usr/src/linux-headers-$(uname -r)" ]; then
        kernel_build_dir="/usr/src/linux-headers-$(uname -r)"
    fi

    if [ -z "$kernel_build_dir" ]; then
        log_warn "未找到内核构建目录，无法编译 NPU 驱动"
        log_warn "跳过内核驱动升级（RKNN Runtime 已更新，可满足大部分需求）"
        log_info "要编译内核驱动，请先安装内核头文件:"
        echo "     sudo apt install linux-headers-$(uname -r)"
        return 0
    fi

    log_info "内核构建目录: ${kernel_build_dir}"

    # 下载 NPU 驱动源码
    if [ ! -f "$NPU_DRIVER_TAR" ]; then
        log_info "下载 NPU 驱动 0.9.8 源码..."
        if wget -q --show-progress "$NPU_DRIVER_URL" -O "$NPU_DRIVER_TAR"; then
            log_info "下载完成"
        else
            log_warn "下载失败，跳过内核驱动升级"
            return 0
        fi
    fi

    # 解压
    local driver_src_dir="/tmp/rknpu_driver_0.9.8"
    rm -rf "$driver_src_dir" 2>/dev/null || true
    mkdir -p "$driver_src_dir"
    tar -xjf "$NPU_DRIVER_TAR" -C "$driver_src_dir" 2>/dev/null || {
        log_warn "解压失败，跳过内核驱动升级"
        return 0
    }

    # 找到 rknpu 驱动源码目录
    local rknpu_src=$(find "$driver_src_dir" -type d -name "rknpu" 2>/dev/null | head -1)
    if [ -z "$rknpu_src" ]; then
        log_warn "未找到 rknpu 驱动源码目录"
        rm -rf "$driver_src_dir"
        return 0
    fi

    log_info "编译 NPU 驱动模块..."
    cd "$rknpu_src"
    make -C "$kernel_build_dir" M="$PWD" modules 2>&1 | tail -10 || {
        log_warn "NPU 驱动编译失败（内核源码可能不匹配）"
        log_info "RKNN Runtime 已更新，NPU 驱动后续再处理"
        cd /
        rm -rf "$driver_src_dir"
        return 0
    }

    # 安装模块
    log_info "安装 NPU 驱动模块..."
    make -C "$kernel_build_dir" M="$PWD" modules_install 2>&1 | tail -5 || {
        log_warn "NPU 驱动安装失败"
        cd /
        rm -rf "$driver_src_dir"
        return 0
    }
    depmod -a

    log_info "NPU 驱动升级完成（重启后生效）"
    cd /
    rm -rf "$driver_src_dir"
    return 0
}

#===============================================================================
# 验证安装结果
#===============================================================================
verify_installation() {
    echo ""
    echo -e "${CYAN}━━━ 4. 验证安装结果 ━━━${NC}"

    local all_ok=true

    # 验证设备节点
    if [ -e /dev/dri/renderD128 ]; then
        log_info "NPU 设备节点: /dev/dri/renderD128 ✓"
        local dev_perms=$(stat -c "%a %U:%G" /dev/dri/renderD128 2>/dev/null)
        log_info "设备权限: ${dev_perms}"
    else
        log_warn "NPU 设备节点: 未找到（可能需要重启）"
        all_ok=false
    fi

    # 验证 Runtime 库
    if ldconfig -p 2>/dev/null | grep -q librknnrt; then
        local lib_path=$(ldconfig -p | grep librknnrt.so | awk '{print $NF}' | head -1)
        log_info "RKNN Runtime: ${lib_path} ✓"
    else
        local manual_found=false
        for p in /usr/lib/librknnrt.so /usr/lib64/librknnrt.so; do
            if [ -f "$p" ]; then
                log_info "RKNN Runtime: ${p} ✓"
                manual_found=true
                break
            fi
        done
        if [ "$manual_found" = false ]; then
            log_error "RKNN Runtime: 未找到"
            all_ok=false
        fi
    fi

    # 简单的功能性测试
    echo ""
    if python3 -c "from rknn.api import RKNN; print('RKNN Python API: OK')" 2>/dev/null; then
        log_info "Python API 测试通过"
    else
        log_warn "Python API 测试不通过（可选，C++ 项目不需要）"
    fi

    if [ "$all_ok" = true ]; then
        echo ""
        log_info "安装验证通过 ✓"
    fi
}

#===============================================================================
# 回滚
#===============================================================================
do_rollback() {
    echo ""
    echo -e "${YELLOW}━━━ 回滚操作 ━━━${NC}"

    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "备份目录不存在，无法回滚"
        return 1
    fi

    log_info "从 ${BACKUP_DIR} 恢复..."

    # 恢复 librknnrt.so
    local restored=false
    for backup_lib in "$BACKUP_DIR"/librknnrt.so*; do
        if [ -f "$backup_lib" ]; then
            local target="/usr/lib/$(basename "$backup_lib")"
            cp "$backup_lib" "$target" 2>/dev/null || \
            cp "$backup_lib" "/usr/lib64/$(basename "$backup_lib")" 2>/dev/null || true
            restored=true
        fi
    done

    if [ "$restored" = true ]; then
        log_info "librknnrt.so 已恢复"
        # 更新 ldconfig
        ldconfig 2>/dev/null || true
    fi

    # 恢复 rknn_server
    if [ -f "$BACKUP_DIR/rknn_server" ]; then
        cp "$BACKUP_DIR/rknn_server" /usr/bin/rknn_server
        chmod +x /usr/bin/rknn_server
        log_info "rknn_server 已恢复"
    fi

    log_info "回滚完成"
    ROLLBACK_NEEDED=false
}

#===============================================================================
# 主函数
#===============================================================================
main() {
    local RUNTIME_ONLY=false
    local FORCE=false
    local DRY_RUN=false

    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --runtime-only) RUNTIME_ONLY=true; shift ;;
            --force)        FORCE=true; shift ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --help|-h)      usage; exit 0 ;;
            *)              echo "未知选项: $1"; usage; exit 1 ;;
        esac
    done

    print_banner

    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        log_error "请以 root 权限运行: sudo bash $0"
        exit 1
    fi

    # 检查是否为 RK3588
    local arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        log_warn "当前架构: ${arch}，此脚本专为 RK3588 (ARM64) 设计"
        log_warn "继续运行可能不兼容"
        if [ "$FORCE" != true ]; then
            echo ""
            read -p "  是否继续？(y/N): " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                log_info "已取消"
                exit 0
            fi
        fi
    fi

    # 获取当前版本
    local versions=$(get_current_versions)
    local current_driver=$(echo "$versions" | cut -d'|' -f1)
    local current_runtime=$(echo "$versions" | cut -d'|' -f2)

    echo "当前状态:"
    echo "  NPU 驱动:    ${current_driver:-未检测到}"
    echo "  RKNN Runtime: ${current_runtime:-未检测到}"
    echo ""

    # Dry-run 模式
    if [ "$DRY_RUN" = true ]; then
        echo -e "${CYAN}━━━ Dry-Run 模式 ━━━${NC}"
        echo ""
        echo "将执行的操作:"
        if [ "$RUNTIME_ONLY" = false ]; then
            echo "  - 备份当前 NPU 状态"
            echo "  - 升级 RKNN Runtime 到 2.3.2"
            echo "  - 升级 NPU 内核驱动到 0.9.8（需要内核头文件）"
        else
            echo "  - 备份当前 RKNN Runtime"
            echo "  - 升级 RKNN Runtime 到 2.3.2"
        fi
        echo "  - 验证安装结果"
        echo ""
        echo "升级后:"
        echo "  NPU 驱动:    ${current_driver} → 0.9.8（推荐）"
        echo "  RKNN Runtime: ${current_runtime} → 2.3.2"
        echo ""
        log_info "Dry-Run 完成，未执行任何实际操作"
        exit 0
    fi

    # 确认
    echo "此操作将:"
    if [ "$RUNTIME_ONLY" = false ]; then
        echo "  • 备份当前 NPU 驱动和 Runtime"
        echo "  • 升级 RKNN Runtime 到 2.3.2"
        echo "  • 尝试升级 NPU 内核驱动到 0.9.8"
    else
        echo "  • 备份当前 RKNN Runtime"
        echo "  • 升级 RKNN Runtime 到 2.3.2"
    fi
    echo "  • 失败时自动回滚"
    echo ""
    read -p "  是否继续？(Y/n): " confirm
    confirm=${confirm:-Y}
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "已取消"
        exit 0
    fi

    # 执行升级
    local upgrade_ok=true

    do_backup || upgrade_ok=false

    if [ "$upgrade_ok" = true ]; then
        install_runtime || upgrade_ok=false
    fi

    if [ "$upgrade_ok" = true ] && [ "$RUNTIME_ONLY" = false ]; then
        install_npu_driver || upgrade_ok=false
    fi

    if [ "$upgrade_ok" = true ]; then
        verify_installation
    fi

    # 处理结果
    echo ""
    if [ "$upgrade_ok" = true ]; then
        echo -e "${GREEN}============================================${NC}"
        echo -e "${GREEN}  升级完成！${NC}"
        echo -e "${GREEN}============================================${NC}"
        if [ "$RUNTIME_ONLY" = false ]; then
            echo ""
            echo "  ℹ 如果升级了内核 NPU 驱动，请重启生效:"
            echo "     sudo reboot"
            echo ""
            echo "  重启后运行验证:"
            echo "     sudo bash check_npu_driver.sh"
        fi
        # 成功，不需要回滚
        ROLLBACK_NEEDED=false
    else
        echo -e "${RED}============================================${NC}"
        echo -e "${RED}  升级过程中出现问题${NC}"
        echo -e "${RED}============================================${NC}"
        echo ""
        if [ -d "$BACKUP_DIR" ]; then
            echo "  备份文件在: ${BACKUP_DIR}"
            echo "  可手动恢复。"
        fi
    fi

    echo ""
    echo -e "${CYAN}━ 版本摘要 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local new_versions=$(get_current_versions)
    local new_driver=$(echo "$new_versions" | cut -d'|' -f1)
    local new_runtime=$(echo "$new_versions" | cut -d'|' -f2)

    echo "  NPU 驱动:    ${current_driver:-∅} → ${new_driver:-∅}"
    echo "  RKNN Runtime: ${current_runtime:-∅} → ${new_runtime:-∅}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
