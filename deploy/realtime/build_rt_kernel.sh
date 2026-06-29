#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit - PREEMPT_RT 内核编译脚本
# Build PREEMPT_RT Kernel for RK3588
# 功能：自动检测板卡内核版本，匹配 RT 补丁，编译 PREEMPT_RT 内核并生成 .deb 包
# 适用：Nanopc T6 / 鲁班猫8 / Radxa Rock 5B / Orange Pi 5 / 飞凌 OK3588
#===============================================================================

set -e

VERSION="v1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATRIX_FILE="${SCRIPT_DIR}/version_matrix.yaml"
WORK_DIR="/tmp/rk3588_rt_kernel_build"
BUILD_LOG="${WORK_DIR}/build.log"

# 内核源码与补丁缓存目录 (避免重复下载)
CACHE_DIR="${HOME}/.cache/rk3588-rt-kernel"

# 编译输出目录
OUTPUT_DIR="${SCRIPT_DIR}/output"

# 默认编译线程数
BUILD_JOBS=$(nproc 2>/dev/null || echo 4)

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 模式标志
DRY_RUN=false
DO_INSTALL=false
FORCE_REDOWNLOAD=false
VERBOSE=false

#===============================================================================
# 工具函数 / Utility Functions
#===============================================================================

print_banner() {
    echo "============================================"
    echo "  RK3588 PREEMPT_RT 内核编译工具 v${VERSION}"
    echo "  RK3588 PREEMPT_RT Kernel Builder"
    echo "============================================"
    echo ""
}

log_info() {
    echo -e "  ${CYAN}[INFO]${NC}  $1"
}

log_ok() {
    echo -e "  ${GREEN}[ OK ]${NC}  $1"
}

log_warn() {
    echo -e "  ${YELLOW}[WARN]${NC}  $1"
}

log_err() {
    echo -e "  ${RED}[ERR ]${NC}  $1"
}

log_step() {
    echo ""
    echo -e "${GREEN}━━━ $1 ━━━${NC}"
}

die() {
    log_err "$1"
    echo ""
    echo "  查看日志获取详情 / Check log for details: ${BUILD_LOG}"
    exit 1
}

# 中英双语打印
bilog() {
    local zh="$1"
    local en="$2"
    echo -e "  → ${zh}  |  ${en}"
}

# 检查命令是否存在
require_cmd() {
    local cmd="$1"
    local pkg="${2:-$cmd}"
    if ! command -v "$cmd" &> /dev/null; then
        die "缺少命令 '$cmd'，请安装: sudo apt install -y $pkg\n       Missing command '$cmd', install: sudo apt install -y $pkg"
    fi
}

#===============================================================================
# 帮助信息 / Help
#===============================================================================
show_help() {
    cat << EOF
用法 / Usage:
  bash build_rt_kernel.sh [选项/OPTIONS]

选项 / Options:
  --dry-run          仅检测内核版本并匹配 RT 补丁，不执行编译
                     Only detect kernel version & match RT patch, skip build
  --install          编译完成后自动安装 .deb 包
                     Auto-install .deb packages after build
  --output-dir DIR   指定 .deb 输出目录 (默认: ${SCRIPT_DIR}/output)
                     Specify .deb output directory (default: ${SCRIPT_DIR}/output)
  -j, --jobs N       编译并行线程数 (默认: CPU 核心数)
                     Number of parallel build jobs (default: CPU cores)
  --force-download   强制重新下载内核源码与补丁
                     Force re-download kernel source and RT patch
  --verbose          显示详细编译日志
                     Show verbose build output
  -h, --help         显示本帮助信息
                     Show this help message

示例 / Examples:
  # 仅检测，不编译
  bash build_rt_kernel.sh --dry-run

  # 编译并生成 .deb 包
  bash build_rt_kernel.sh

  # 编译并自动安装
  bash build_rt_kernel.sh --install

  # 指定输出目录和编译线程数
  bash build_rt_kernel.sh --output-dir /home/ubuntu/rt-debs -j 6

EOF
    exit 0
}

#===============================================================================
# 参数解析 / Argument Parsing
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --install)
                DO_INSTALL=true
                shift
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -j|--jobs)
                BUILD_JOBS="$2"
                shift 2
                ;;
            --force-download)
                FORCE_REDOWNLOAD=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                echo -e "${RED}未知选项 / Unknown option: $1${NC}"
                echo "使用 --help 查看帮助 / Use --help for usage"
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# 预检 / Pre-flight Checks
#===============================================================================
preflight_check() {
    log_step "1. 预检 / Pre-flight Checks"

    # 检查是否在 RK3588 板卡上运行
    bilog "检测板卡平台..." "Checking board platform..."
    if grep -qi "rk3588" /proc/device-tree/compatible 2>/dev/null; then
        log_ok "RK3588 平台 / RK3588 platform detected"
    else
        log_warn "未检测到 RK3588 设备树，可能不是 RK3588 板卡"
        log_warn "RK3588 device-tree not found, may not be an RK3588 board"
    fi

    # 检查必要命令
    bilog "检查编译依赖..." "Checking build dependencies..."
    local missing_pkgs=()
    local cmds=("wget" "make" "gcc" "dpkg-deb" "tar" "xz" "patch" "bison" "flex")
    local pkgs=("wget" "make" "gcc" "dpkg-dev" "tar" "xz-utils" "patch" "bison" "flex")

    for i in "${!cmds[@]}"; do
        if ! command -v "${cmds[$i]}" &> /dev/null; then
            missing_pkgs+=("${pkgs[$i]}")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_warn "缺少以下包 / Missing packages: ${missing_pkgs[*]}"
        echo ""
        echo "  请运行以下命令安装 / Please install with:"
        echo "  sudo apt update && sudo apt install -y ${missing_pkgs[*]}"
        echo "  sudo apt install -y build-essential libncurses-dev libssl-dev libelf-dev bc rsync cpio"
        echo ""

        if $DRY_RUN; then
            log_warn "干跑模式：跳过依赖安装 / Dry-run: skipping dep installation"
        else
            read -p "  是否自动安装? Auto-install? [Y/n] " -r
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                sudo apt update && sudo apt install -y "${missing_pkgs[@]}" build-essential \
                    libncurses-dev libssl-dev libelf-dev bc rsync cpio || die "依赖安装失败 / Dependency install failed"
            else
                die "缺少必要依赖，无法继续 / Required dependencies missing, aborting"
            fi
        fi
    else
        log_ok "所有编译依赖已满足 / All build dependencies satisfied"
    fi

    # 检查磁盘空间 (至少需要 15GB)
    bilog "检查磁盘空间..." "Checking disk space..."
    local available_gb=$(df -BG "${WORK_DIR%/*}" 2>/dev/null | tail -1 | awk '{print $4}' | sed 's/G//')
    if [[ -z "$available_gb" ]] || [[ "$available_gb" -lt 15 ]]; then
        log_warn "磁盘剩余空间: ${available_gb:-未知}GB，建议至少 15GB"
        log_warn "Available disk space: ${available_gb:-unknown}GB, recommend 15GB+"
        if [[ "$available_gb" -lt 10 ]]; then
            die "磁盘空间不足 / Insufficient disk space"
        fi
    else
        log_ok "磁盘剩余空间: ${available_gb}GB / Available disk: ${available_gb}GB"
    fi

    # 检查 MATRIX_FILE 是否存在
    if [[ ! -f "$MATRIX_FILE" ]]; then
        die "版本矩阵文件不存在: ${MATRIX_FILE}\n       Version matrix file not found: ${MATRIX_FILE}"
    fi
    log_ok "版本矩阵: ${MATRIX_FILE} / Version matrix found"
}

#===============================================================================
# 内核版本检测 / Kernel Version Detection
#===============================================================================
detect_kernel_version() {
    log_step "2. 内核版本检测 / Kernel Version Detection"

    local full_version
    full_version=$(uname -r)
    bilog "当前运行内核: ${full_version}" "Running kernel: ${full_version}"

    # 提取主版本号 (如 5.10.110)
    # uname -r 可能返回 "5.10.110-rockchip-rk3588" 或 "5.10.110-rt65"
    # 需要提取开头的纯数字版本号
    DETECTED_KV=$(echo "$full_version" | grep -oP '^\d+\.\d+\.\d+')

    if [[ -z "$DETECTED_KV" ]]; then
        die "无法解析内核版本: $full_version\n       Cannot parse kernel version: $full_version"
    fi

    log_ok "检测到内核版本 / Detected kernel version: ${DETECTED_KV}"

    # 检查是否已经是 RT 内核
    if echo "$full_version" | grep -q "rt"; then
        log_warn "当前已经是 PREEMPT_RT 内核！/ Already running PREEMPT_RT kernel!"
        if ! $FORCE_REDOWNLOAD; then
            read -p "  仍要继续编译? Continue anyway? [y/N] " -r
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    fi

    # 提取主版本号 (5.10, 6.1, etc.)
    MAJOR_MINOR=$(echo "$DETECTED_KV" | grep -oP '^\d+\.\d+')
}

#===============================================================================
# 版本矩阵查询 / Version Matrix Lookup
#===============================================================================
lookup_rt_patch() {
    log_step "3. RT 补丁匹配 / RT Patch Matching"

    local kv="$1"
    bilog "在版本矩阵中查找 ${kv}..." "Looking up ${kv} in version matrix..."

    # 用 awk 解析 YAML 格式的版本矩阵
    # 解析逻辑: 按条目遍历，匹配 bsp_version 字段
    local result
    result=$(awk -v target="$kv" '
        BEGIN { bsp=""; patch=""; rtver=""; src=""; note=""; found=0 }
        /^  - bsp_version:/ {
            if (found) exit
            bsp=$0; sub(/.*bsp_version: *"/, "", bsp); sub(/".*/, "", bsp)
        }
        /^    rt_patch:/     { patch=$0;  sub(/.*rt_patch: *"/, "", patch);  sub(/".*/, "", patch) }
        /^    rt_version:/   { rtver=$0;  sub(/.*rt_version: *"/, "", rtver);  sub(/".*/, "", rtver) }
        /^    kernel_source:/{ src=$0;    sub(/.*kernel_source: *"/, "", src);    sub(/".*/, "", src) }
        /^    notes:/        { note=$0;   sub(/.*notes: *"/, "", note);   sub(/".*/, "", note) }
        /^  - bsp_version:/ {
            # 下一个条目开始了，检查上一个
            if (bsp == target) { found=1; exit }
        }
        END {
            if (bsp == target || found) {
                print bsp "|" patch "|" rtver "|" src "|" note
            }
        }
    ' "$MATRIX_FILE")

    if [[ -z "$result" ]]; then
        log_err "未找到 ${kv} 对应的 RT 补丁"
        echo ""
        echo "  当前支持的 BSP 版本 / Supported BSP versions:"
        awk '/bsp_version:/ { v=$0; sub(/.*bsp_version: *"/, "", v); sub(/".*/, "", v); print "    - " v }' "$MATRIX_FILE"
        echo ""
        die "请在 version_matrix.yaml 中添加 ${kv} 的条目\n       Please add ${kv} entry to version_matrix.yaml"
    fi

    # 解析结果
    MATCHED_BSP=$(echo "$result"    | cut -d'|' -f1)
    RT_PATCH_FILE=$(echo "$result"  | cut -d'|' -f2)
    RT_VERSION=$(echo "$result"     | cut -d'|' -f3)
    KERNEL_SRC_URL=$(echo "$result" | cut -d'|' -f4)
    MATCHED_NOTE=$(echo "$result"   | cut -d'|' -f5)

    # 读取补丁基址
    PATCH_BASE_URL=$(awk '/^patch_base_url:/ { v=$0; sub(/.*patch_base_url: *"/, "", v); sub(/".*/, "", v); print v }' "$MATRIX_FILE")
    PATCH_BASE_URL="${PATCH_BASE_URL:-https://cdn.kernel.org/pub/linux/kernel/projects/rt}"

    # 补丁 URL (RT 补丁在 kernel.org 上可能以 .xz 压缩格式提供)
    RT_PATCH_URL="${PATCH_BASE_URL}/${MAJOR_MINOR}/${RT_PATCH_FILE}.xz"

    log_ok "匹配成功 / Match found:"
    echo "       BSP 版本:  ${MATCHED_BSP}"
    echo "       RT 补丁:   ${RT_PATCH_FILE}  (${RT_VERSION})"
    echo "       内核源码:  ${KERNEL_SRC_URL}"
    echo "       补丁 URL:  ${RT_PATCH_URL}"
    if [[ -n "$MATCHED_NOTE" ]]; then
        echo "       备注:      ${MATCHED_NOTE}"
    fi
}

#===============================================================================
# 下载源码与补丁 / Download Source & Patch
#===============================================================================
download_sources() {
    log_step "4. 下载源码与补丁 / Download Sources"

    mkdir -p "$CACHE_DIR"

    local kernel_tarball="${CACHE_DIR}/linux-${MATCHED_BSP}.tar.xz"
    local patch_file="${CACHE_DIR}/${RT_PATCH_FILE}"
    local patch_xz="${CACHE_DIR}/${RT_PATCH_FILE}.xz"

    # 下载内核源码
    if [[ -f "$kernel_tarball" ]] && ! $FORCE_REDOWNLOAD; then
        log_ok "内核源码已缓存 / Kernel source cached: ${kernel_tarball}"
    else
        bilog "下载内核源码..." "Downloading kernel source..."
        wget -q --show-progress -O "$kernel_tarball" "$KERNEL_SRC_URL" || {
            log_warn "wget 失败，尝试 curl / wget failed, trying curl..."
            curl -L -o "$kernel_tarball" "$KERNEL_SRC_URL" || die "下载内核源码失败 / Failed to download kernel source"
        }
        log_ok "内核源码下载完成 / Kernel source downloaded"
    fi

    # 下载 RT 补丁
    if [[ -f "$patch_file" ]] && ! $FORCE_REDOWNLOAD; then
        log_ok "RT 补丁已缓存 / RT patch cached: ${patch_file}"
    else
        bilog "下载 RT 补丁..." "Downloading RT patch..."
        # 先尝试 .xz 格式
        if wget -q --show-progress -O "$patch_xz" "$RT_PATCH_URL" 2>/dev/null; then
            log_ok "下载 .xz 补丁，正在解压 / Downloaded .xz patch, extracting..."
            xz -d -f "$patch_xz" || die "解压补丁失败 / Failed to extract patch"
            log_ok "RT 补丁就绪 / RT patch ready: ${patch_file}"
        else
            # 尝试非 .xz 格式
            RT_PATCH_URL_NOXZ="${PATCH_BASE_URL}/${MAJOR_MINOR}/${RT_PATCH_FILE}"
            log_info "未找到 .xz 格式，尝试直接下载 / .xz not found, trying raw patch..."
            wget -q --show-progress -O "$patch_file" "$RT_PATCH_URL_NOXZ" || {
                # 尝试较老版本路径
                RT_PATCH_URL_OLD="${PATCH_BASE_URL}/older/${RT_PATCH_FILE}.xz"
                log_info "尝试旧路径 / Trying older path: ${RT_PATCH_URL_OLD}"
                wget -q --show-progress -O "$patch_xz" "$RT_PATCH_URL_OLD" && xz -d -f "$patch_xz" || {
                    die "下载 RT 补丁失败\n       手动下载 / Manual download: ${RT_PATCH_URL}\n       Failed to download RT patch"
                }
            }
        fi
    fi
}

#===============================================================================
# 解压与打补丁 / Extract & Apply Patch
#===============================================================================
extract_and_patch() {
    log_step "5. 解压与打补丁 / Extract & Apply Patch"

    # 清理旧构建目录
    if [[ -d "$WORK_DIR" ]]; then
        bilog "清理旧构建目录..." "Cleaning old build directory..."
        rm -rf "$WORK_DIR"
    fi
    mkdir -p "$WORK_DIR"

    local kernel_tarball="${CACHE_DIR}/linux-${MATCHED_BSP}.tar.xz"
    local patch_file="${CACHE_DIR}/${RT_PATCH_FILE}"

    # 解压内核源码
    bilog "解压内核源码..." "Extracting kernel source..."
    tar -xf "$kernel_tarball" -C "$WORK_DIR" || die "解压内核源码失败 / Failed to extract kernel source"
    log_ok "内核源码解压完成 / Kernel source extracted"

    # 找到解压后的目录
    KERNEL_SRC_DIR=$(find "$WORK_DIR" -maxdepth 1 -type d -name "linux-*" | head -1)
    if [[ -z "$KERNEL_SRC_DIR" ]]; then
        die "未找到解压后的内核目录 / Cannot find extracted kernel directory"
    fi
    log_ok "内核目录 / Kernel directory: ${KERNEL_SRC_DIR}"

    # 检查补丁是否已应用
    if grep -q "CONFIG_PREEMPT_RT=y" "${KERNEL_SRC_DIR}/.config" 2>/dev/null; then
        log_warn "检测到已应用 RT 补丁 / RT patch appears already applied"
        if ! $FORCE_REDOWNLOAD; then
            read -p "  跳过打补丁? Skip patching? [Y/n] " -r
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                log_ok "跳过打补丁步骤 / Skipping patch step"
                return
            fi
        fi
    fi

    # 应用 RT 补丁
    bilog "应用 PREEMPT_RT 补丁..." "Applying PREEMPT_RT patch..."
    cd "$KERNEL_SRC_DIR"

    # 对于大补丁，使用 --dry-run 先测试
    if ! patch -p1 --dry-run -i "$patch_file" &>/dev/null; then
        log_warn "补丁 dry-run 有冲突，尝试 -p0 / dry-run conflict, trying -p0..."
        if patch -p0 --dry-run -i "$patch_file" &>/dev/null; then
            PATCH_LEVEL="p0"
        else
            log_err "补丁与当前源码不兼容 / Patch incompatible with kernel source"
            log_err "补丁文件 / Patch file: ${patch_file}"
            log_err "目标目录 / Target dir: ${KERNEL_SRC_DIR}"
            die "请检查 BSP 版本是否匹配 / Please verify BSP version matches"
        fi
    else
        PATCH_LEVEL="p1"
    fi

    # 正式打补丁
    patch -${PATCH_LEVEL} -s -i "$patch_file" || die "补丁应用失败 / Patch application failed"
    log_ok "RT 补丁应用成功 / RT patch applied successfully (patch -${PATCH_LEVEL})"
}

#===============================================================================
# 内核配置 / Kernel Configuration
#===============================================================================
configure_kernel() {
    log_step "6. 内核配置 / Kernel Configuration"

    cd "$KERNEL_SRC_DIR"

    # 1. 优先用当前运行内核的配置作为基线
    if [[ -f /proc/config.gz ]]; then
        bilog "从 /proc/config.gz 加载当前内核配置..." "Loading current kernel config from /proc/config.gz..."
        zcat /proc/config.gz > .config
        log_ok "配置加载完成 / Config loaded"
    elif [[ -f "/boot/config-$(uname -r)" ]]; then
        bilog "从 /boot/config 加载当前内核配置..." "Loading current kernel config from /boot..."
        cp "/boot/config-$(uname -r)" .config
        log_ok "配置加载完成 / Config loaded"
    else
        log_warn "未找到当前内核配置，生成默认配置 / No current config found, generating default"
        # 为 RK3588 使用通用 ARM64 配置
        make ARCH=arm64 defconfig 2>&1 | tee -a "$BUILD_LOG" || die "defconfig 失败"
    fi

    # 2. 启用 PREEMPT_RT 相关选项
    bilog "启用 PREEMPT_RT 配置..." "Enabling PREEMPT_RT options..."

    # 使用 scripts/config 修改配置
    local config_script="${KERNEL_SRC_DIR}/scripts/config"
    if [[ ! -x "$config_script" ]]; then
        # 旧内核可能没有此脚本，使用 sed
        log_info "使用 sed 修改 .config / Using sed to modify .config"
        sed -i 's/^# CONFIG_PREEMPT_RT is not set/CONFIG_PREEMPT_RT=y/' .config
        sed -i 's/^CONFIG_PREEMPT=.*/CONFIG_PREEMPT=y/' .config
    else
        # 禁用其他抢占模型
        "$config_script" --disable CONFIG_PREEMPT_NONE 2>/dev/null || true
        "$config_script" --disable CONFIG_PREEMPT_VOLUNTARY 2>/dev/null || true
        # 启用 PREEMPT_RT
        "$config_script" --enable CONFIG_PREEMPT 2>/dev/null || true
        "$config_script" --enable CONFIG_PREEMPT_RT 2>/dev/null || true
        # 同时设置一些优化选项
        "$config_script" --enable CONFIG_HIGH_RES_TIMERS 2>/dev/null || true
        "$config_script" --enable CONFIG_NO_HZ_FULL 2>/dev/null || true
    fi

    # 验证
    if ! grep -q "CONFIG_PREEMPT_RT=y" .config 2>/dev/null; then
        log_err ".config 中未找到 CONFIG_PREEMPT_RT=y"
        log_err "正在追加 / Appending manually..."
        echo "CONFIG_PREEMPT_RT=y" >> .config
    fi

    # 3. 刷新依赖配置 (将新选项的依赖自动补齐)
    bilog "刷新内核配置依赖..." "Refreshing kernel config dependencies..."
    make ARCH=arm64 olddefconfig 2>&1 | tee -a "$BUILD_LOG" || {
        log_warn "olddefconfig 失败，尝试 oldconfig / olddefconfig failed, trying oldconfig..."
        yes "" | make ARCH=arm64 oldconfig 2>&1 | tee -a "$BUILD_LOG" || die "内核配置失败 / Kernel config failed"
    }

    log_ok "内核配置完成 / Kernel configuration complete"
}

#===============================================================================
# 编译内核 / Build Kernel
#===============================================================================
build_kernel() {
    log_step "7. 编译内核 / Building Kernel"

    cd "$KERNEL_SRC_DIR"

    local start_time
    start_time=$(date +%s)

    bilog "开始编译 (jobs=${BUILD_JOBS})..." "Building kernel (jobs=${BUILD_JOBS})..."
    echo "  日志文件 / Log file: ${BUILD_LOG}"
    echo ""

    if $VERBOSE; then
        make ARCH=arm64 -j"${BUILD_JOBS}" Image dtbs modules 2>&1 | tee -a "$BUILD_LOG"
        BUILD_EXIT=${PIPESTATUS[0]}
    else
        make ARCH=arm64 -j"${BUILD_JOBS}" Image dtbs modules 2>&1 | tee -a "$BUILD_LOG" | \
            grep --line-buffered -E "(CC|LD|AR|Kernel:|Error|error:|warning:|失败|错误)" || true
        BUILD_EXIT=${PIPESTATUS[0]}
    fi

    if [[ $BUILD_EXIT -ne 0 ]]; then
        die "内核编译失败！查看日志 / Build failed! Check log: ${BUILD_LOG}"
    fi

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    log_ok "编译完成 / Build complete! (耗时 / elapsed: ${minutes}m ${seconds}s)"
}

#===============================================================================
# 生成 .deb 包 / Package .deb
#===============================================================================
package_deb() {
    log_step "8. 生成 .deb 包 / Packaging .deb"

    cd "$KERNEL_SRC_DIR"

    mkdir -p "$OUTPUT_DIR"

    # 创建临时安装目录
    local deb_tmp="${WORK_DIR}/deb_tmp"
    rm -rf "$deb_tmp"
    mkdir -p "${deb_tmp}/boot"

    local kernel_release
    kernel_release=$(make ARCH=arm64 kernelrelease 2>/dev/null || echo "${MATCHED_BSP}-rt${RT_VERSION}+")
    local pkg_name="linux-image-${kernel_release}"
    local pkg_dir="${deb_tmp}/${pkg_name}"
    local deb_file="${OUTPUT_DIR}/${pkg_name}_arm64.deb"

    bilog "打包 ${pkg_name}..." "Packaging ${pkg_name}..."

    # 创建 DEBIAN 控制目录
    mkdir -p "${pkg_dir}/DEBIAN"
    mkdir -p "${pkg_dir}/boot"

    # control 文件
    cat > "${pkg_dir}/DEBIAN/control" << CONTROL_EOF
Package: ${pkg_name}
Version: ${kernel_release}
Architecture: arm64
Maintainer: RK3588 Industrial Toolkit <rt@rk3588.toolkit>
Description: PREEMPT_RT Linux Kernel for RK3588
 Linux kernel ${MATCHED_BSP} with PREEMPT_RT patch ${RT_VERSION}
 Built for Rockchip RK3588 platform.
 .
 适用于 RK3588 平台的 PREEMPT_RT 实时内核。
CONTROL_EOF

    # postinst 脚本 (安装后更新引导)
    cat > "${pkg_dir}/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e
echo "Updating boot configuration..."
# 更新 extlinux 或 grub
if command -v update-extlinux &>/dev/null; then
    update-extlinux
elif command -v update-grub &>/dev/null; then
    update-grub
fi
echo "PREEMPT_RT kernel installed. Please reboot to activate."
echo "PREEMPT_RT 内核已安装。请重启以激活。"
POSTINST_EOF
    chmod +x "${pkg_dir}/DEBIAN/postinst"

    # 复制内核镜像
    if [[ -f "arch/arm64/boot/Image" ]]; then
        cp arch/arm64/boot/Image "${pkg_dir}/boot/vmlinuz-${kernel_release}"
        log_ok "内核镜像 / Image: vmlinuz-${kernel_release}"
    else
        die "未找到内核镜像文件 / Kernel image not found"
    fi

    # 复制设备树
    if ls arch/arm64/boot/dts/rockchip/rk3588*.dtb 1>/dev/null 2>&1; then
        mkdir -p "${pkg_dir}/boot/dtbs/${kernel_release}"
        cp arch/arm64/boot/dts/rockchip/rk3588*.dtb "${pkg_dir}/boot/dtbs/${kernel_release}/" 2>/dev/null || true
        log_ok "设备树 / Device trees copied"
    else
        log_warn "未找到 rk3588 设备树 / No rk3588 dtbs found"
    fi

    # 安装模块
    bilog "安装内核模块..." "Installing kernel modules..."
    make ARCH=arm64 INSTALL_MOD_PATH="${pkg_dir}" modules_install 2>&1 | tee -a "$BUILD_LOG"

    # 构建 .deb
    bilog "构建 .deb 包..." "Building .deb package..."
    dpkg-deb --build "${pkg_dir}" "$deb_file" || die "deb 打包失败 / deb packaging failed"

    log_ok ".deb 包生成 / Package created: ${deb_file}"

    # 显示包信息
    echo ""
    echo "  📦 包信息 / Package Info:"
    dpkg-deb --info "$deb_file" | sed 's/^/     /'

    # 保存路径供后续安装使用
    DEB_FILE="$deb_file"
}

#===============================================================================
# 安装 .deb 包 / Install .deb
#===============================================================================
install_deb() {
    log_step "9. 安装 / Installing"

    if [[ -z "$DEB_FILE" ]] || [[ ! -f "$DEB_FILE" ]]; then
        die "未找到 .deb 包文件 / .deb package not found"
    fi

    bilog "安装内核包 / Installing kernel package: ${DEB_FILE}"

    if [[ $EUID -ne 0 ]]; then
        log_info "需要 root 权限安装 / Root required for installation"
        sudo dpkg -i "$DEB_FILE" || die "安装失败 / Installation failed"
    else
        dpkg -i "$DEB_FILE" || die "安装失败 / Installation failed"
    fi

    log_ok "安装完成 / Installation complete!"

    echo ""
    echo "  ┌─────────────────────────────────────────────┐"
    echo "  │  ⚡ PREEMPT_RT 内核安装完成!                  │"
    echo "  │  ⚡ PREEMPT_RT kernel installed!              │"
    echo "  │                                               │"
    echo "  │  请重启系统以激活新内核:                      │"
    echo "  │  Please reboot to activate the new kernel:    │"
    echo "  │                                               │"
    echo "  │    sudo reboot                                │"
    echo "  │                                               │"
    echo "  │  重启后验证:                                   │"
    echo "  │  Verify after reboot:                         │"
    echo "  │                                               │"
    echo "  │    uname -r                                   │"
    echo "  │    cat /sys/kernel/realtime                   │"
    echo "  └─────────────────────────────────────────────┘"
    echo ""
}

#===============================================================================
# 汇总 / Summary
#===============================================================================
print_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  编译汇总 / Build Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  当前内核:    ${DETECTED_KV}"
    echo "  BSP 版本:    ${MATCHED_BSP}"
    echo "  RT 补丁:     ${RT_PATCH_FILE} (${RT_VERSION})"
    echo "  内核源码:    ${KERNEL_SRC_DIR:-N/A}"
    echo "  输出目录:    ${OUTPUT_DIR}"
    if [[ -n "$DEB_FILE" ]]; then
        echo "  .deb 包:     ${DEB_FILE}"
    fi
    echo "  日志文件:    ${BUILD_LOG}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

#===============================================================================
# 主流程 / Main
#===============================================================================
main() {
    print_banner

    parse_args "$@"

    # 初始化日志
    mkdir -p "$(dirname "$BUILD_LOG")"
    echo "RK3588 PREEMPT_RT Kernel Build Log - $(date)" > "$BUILD_LOG"
    echo "========================================" >> "$BUILD_LOG"

    preflight_check

    detect_kernel_version

    lookup_rt_patch "$DETECTED_KV"

    # 干跑模式：检测完成后退出
    if $DRY_RUN; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ✅ 干跑检测完成 / Dry-run complete"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  检测结果 / Detection results:"
        echo "  ├─ 当前内核 / Running kernel: ${DETECTED_KV}"
        echo "  ├─ BSP 版本  / BSP version:   ${MATCHED_BSP}"
        echo "  ├─ RT 补丁   / RT patch:      ${RT_PATCH_FILE} (${RT_VERSION}))"
        echo "  ├─ 内核源码  / Kernel source: ${KERNEL_SRC_URL}"
        echo "  └─ 补丁 URL  / Patch URL:     ${RT_PATCH_URL}"
        echo ""
        echo "  执行编译命令 / To build, run:"
        echo "    bash build_rt_kernel.sh"
        echo ""
        exit 0
    fi

    download_sources
    extract_and_patch
    configure_kernel
    build_kernel
    package_deb

    print_summary

    if $DO_INSTALL; then
        install_deb
    else
        echo -e "  💡 提示 / Tip: 使用 --install 自动安装 .deb 包"
        echo -e "     Use --install to auto-install the .deb package"
        echo ""
    fi

    echo -e "${GREEN}✅ PREEMPT_RT 内核编译完成! / Build successful!${NC}"
    echo ""
}

main "$@"
