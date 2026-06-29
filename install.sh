#!/bin/bash
#===============================================================================
# RK3588 Industrial Toolkit - 根级安装脚本 (增强版)
# 使用:
#   bash install.sh                  # 交互式菜单
#   bash install.sh --full           # 全部安装
#   bash install.sh --minimal        # 最小安装（仅核心）
#   bash install.sh --ai-only        # 仅推理引擎
#   bash install.sh --help           # 帮助
#===============================================================================

set -e

# ── 全局变量 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/rk3588-toolkit"
LOG_FILE="/var/log/rk3588-install.log"
INSTALL_MODE="interactive"       # interactive | full | minimal | ai-only
INSTALL_COMPONENTS=""            # 由菜单选中的组件列表
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# ── 颜色定义 ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 日志函数 ──────────────────────────────────────────────────────────────
log_init() {
    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
        LOG_FILE="/tmp/rk3588-install-$(date +%Y%m%d_%H%M%S).log"
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    }

    # 写入日志头
    cat > "$LOG_FILE" << LOG_HEAD
================================================================================
RK3588 Industrial Toolkit 安装日志
开始时间: ${START_TIME}
安装模式: ${INSTALL_MODE}
设备架构: $(uname -m)
内核版本: $(uname -r)
================================================================================

LOG_HEAD
}

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE"
}

log_info()  { log_msg "INFO" "$@"; }
log_warn()  { log_msg "WARN" "$@"; }
log_error() { log_msg "ERROR" "$@"; }

# ── 输出函数（终端 + 日志双写）────────────────────────────────────────────
print_banner() {
    local banner
    banner="
============================================
  RK3588 Industrial Toolkit 安装脚本
  Industrial Toolkit Installer v2.0
============================================"
    echo "$banner"
    log_info "安装脚本启动"
}

print_step() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
    log_info "$1"
}

print_ok() {
    echo -e "  ${GREEN}✅${NC} $1"
    log_info "PASS: $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC}  $1"
    log_warn "$1"
}

print_fail() {
    echo -e "  ${RED}❌${NC} $1"
    log_error "$1"
}

# ── 帮助信息 ──────────────────────────────────────────────────────────────
show_help() {
    cat << HELP_EOF
RK3588 Industrial Toolkit 安装脚本

用法:
  bash install.sh [选项]

选项:
  --full        全部安装 — 包含所有组件（引擎/协议/诊断/基准/文档）
  --minimal     最小安装 — 仅安装核心运行时（环境检测 + 基本工具）
  --ai-only     仅推理引擎 — 只安装 AI 推理引擎和相关配置
  --help, -h    显示此帮助信息

无选项时进入交互式菜单，可按需选择组件。

组件说明:
  engine       AI 推理引擎 (RKNN)
  protocols    Modbus TCP / OPC UA 工业协议支持
  tools        诊断工具 (diagnose.sh) + 基准测试 (benchmark.sh)
  docs         部署文档 (中/英文)
  demos        YOLOv5 / Modbus 示例 Demo

示例:
  bash install.sh                  # 交互式安装
  bash install.sh --ai-only        # 仅安装推理引擎
  bash install.sh --full           # 完整安装所有组件

日志文件: ${LOG_FILE}
HELP_EOF
    exit 0
}

# ── 解析命令行参数 ────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full)
                INSTALL_MODE="full"
                INSTALL_COMPONENTS="engine protocols tools docs demos"
                shift
                ;;
            --minimal)
                INSTALL_MODE="minimal"
                INSTALL_COMPONENTS="tools"
                shift
                ;;
            --ai-only)
                INSTALL_MODE="ai-only"
                INSTALL_COMPONENTS="engine demos"
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
    done
}

# ── 交互式菜单 ────────────────────────────────────────────────────────────
interactive_menu() {
    # 仅在终端下显示交互菜单
    if [ ! -t 0 ]; then
        print_warn "非交互式终端，使用默认全部安装"
        INSTALL_MODE="full"
        INSTALL_COMPONENTS="engine protocols tools docs demos"
        return
    fi

    echo ""
    echo -e "${BOLD}请选择要安装的组件（输入数字，多个用空格分隔）:${NC}"
    echo ""
    echo "  1) AI 推理引擎        (RKNN 运行时 + 配置文件)"
    echo "  2) 工业协议支持       (Modbus TCP / OPC UA)"
    echo "  3) 诊断 + 基准工具    (diagnose.sh / benchmark.sh)"
    echo "  4) 部署文档           (中/英文文档)"
    echo "  5) Demo 示例          (YOLOv5 + Modbus Demo)"
    echo "  6) 全部安装"
    echo "  7) 退出"
    echo ""

    read -r -p "请输入选择 [默认: 6 全部安装]: " choices
    choices="${choices:-6}"

    # 解析选择
    local selected=""
    for choice in $choices; do
        case "$choice" in
            1) selected="$selected engine" ;;
            2) selected="$selected protocols" ;;
            3) selected="$selected tools" ;;
            4) selected="$selected docs" ;;
            5) selected="$selected demos" ;;
            6) selected="engine protocols tools docs demos"; break ;;
            7) echo "已取消安装"; log_info "用户取消安装"; exit 0 ;;
            *) echo -e "${YELLOW}忽略无效选择: $choice${NC}" ;;
        esac
    done

    if [ -z "$selected" ]; then
        echo -e "${YELLOW}未选择任何组件，默认全部安装${NC}"
        selected="engine protocols tools docs demos"
    fi

    INSTALL_COMPONENTS="$selected"
    INSTALL_MODE="interactive"

    echo ""
    echo -e "已选择组件: ${GREEN}$(echo $INSTALL_COMPONENTS | tr ' ' ', ')${NC}"
    echo ""

    read -r -p "确认继续安装? [Y/n] " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消安装"
        log_info "用户取消安装"
        exit 0
    fi
}

has_component() {
    local comp="$1"
    [[ " $INSTALL_COMPONENTS " == *" $comp "* ]]
}

# ── 架构检查 ──────────────────────────────────────────────────────────────
check_arch() {
    print_step "架构检查"
    local ARCH
    ARCH=$(uname -m)
    if [ "$ARCH" != "aarch64" ]; then
        print_warn "当前架构: $ARCH"
        echo "         此工具链为 RK3588 (ARM64) 设计"
        echo "         安装脚本将仅复制文件，不执行板级检测"
        log_info "非 ARM64 架构 ($ARCH)，跳过板级检测"
    else
        print_ok "检测到 ARM64 架构 (RK3588 兼容)"
    fi
}

# ── 备份旧版本 ────────────────────────────────────────────────────────────
backup_old() {
    if [ -d "$INSTALL_DIR" ]; then
        local BACKUP_DIR="${INSTALL_DIR}.bak.$(date +%Y%m%d_%H%M%S)"
        print_step "备份旧版本"
        mv "$INSTALL_DIR" "$BACKUP_DIR"
        print_ok "已备份到: $BACKUP_DIR"
        log_info "备份旧版本: $BACKUP_DIR"
    fi
}

# ── 创建目录结构 ──────────────────────────────────────────────────────────
create_dirs() {
    print_step "创建目录结构"
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/models"
    mkdir -p "$INSTALL_DIR/demo"
    mkdir -p "$INSTALL_DIR/configs"
    mkdir -p "$INSTALL_DIR/tools"
    mkdir -p "$INSTALL_DIR/logs"
    print_ok "目录结构已创建"
    log_info "目录结构创建完成: $INSTALL_DIR"
}

# ── 各组件安装函数 ────────────────────────────────────────────────────────
install_engine() {
    print_step "安装 AI 推理引擎"

    # 复制引擎相关文件
    cp -r "${SCRIPT_DIR}/deploy/engine" "$INSTALL_DIR/engine" 2>/dev/null && {
        print_ok "推理引擎核心已安装"
        log_info "引擎文件复制完成"
    } || {
        print_warn "deploy/engine 目录不存在，跳过引擎核心"
        log_warn "deploy/engine 目录不存在"
    }

    # 复制配置文件
    cp -r "${SCRIPT_DIR}/configs"/* "$INSTALL_DIR/configs/" 2>/dev/null && {
        print_ok "引擎配置已安装"
        log_info "配置文件复制完成"
    } || {
        print_warn "配置文件复制失败（可能目录为空）"
        log_warn "configs 目录复制失败"
    }

    # 复制 NPU 驱动补丁
    if [ -d "${SCRIPT_DIR}/patches/npu_driver" ]; then
        mkdir -p "$INSTALL_DIR/npu_patches"
        cp -r "${SCRIPT_DIR}/patches/npu_driver"/* "$INSTALL_DIR/npu_patches/"
        print_ok "NPU 驱动补丁已安装"
        log_info "NPU 补丁复制完成"
    fi
}

install_protocols() {
    print_step "安装工业协议支持"

    cp -r "${SCRIPT_DIR}/deploy/protocol" "$INSTALL_DIR/protocol" 2>/dev/null && {
        print_ok "协议栈已安装 (Modbus + OPC UA)"
        log_info "协议栈文件复制完成"
    } || {
        print_warn "deploy/protocol 目录不存在，跳过协议栈"
        log_warn "deploy/protocol 目录不存在"
    }
}

install_tools() {
    print_step "安装诊断 & 基准工具"

    # 环境检测
    cp -r "${SCRIPT_DIR}/deploy_scripts/env_check" "$INSTALL_DIR/env_check" 2>/dev/null && {
        print_ok "环境检测工具已安装"
        log_info "env_check 复制完成"
    } || print_warn "env_check 目录不存在"

    # 诊断工具
    if [ -d "${SCRIPT_DIR}/tools/diagnose" ]; then
        cp -r "${SCRIPT_DIR}/tools/diagnose"/* "$INSTALL_DIR/tools/"
        print_ok "诊断工具已安装 (diagnose.sh)"
        log_info "diagnose 工具复制完成"
    fi

    # 基准测试
    if [ -d "${SCRIPT_DIR}/tools/benchmark" ]; then
        cp -r "${SCRIPT_DIR}/tools/benchmark"/* "$INSTALL_DIR/tools/"
        print_ok "基准测试工具已安装 (benchmark.sh)"
        log_info "benchmark 工具复制完成"
    fi

    # 软链接
    ln -sf "$INSTALL_DIR/tools/diagnose.sh" /usr/local/bin/rk3588-diagnose 2>/dev/null && {
        print_ok "软链接: rk3588-diagnose → /usr/local/bin/"
    } || print_warn "无法创建 rk3588-diagnose 软链接（可能权限不足）"

    ln -sf "$INSTALL_DIR/tools/benchmark.sh" /usr/local/bin/rk3588-bench 2>/dev/null && {
        print_ok "软链接: rk3588-bench → /usr/local/bin/"
    } || print_warn "无法创建 rk3588-bench 软链接（可能权限不足）"

    # PATH 配置
    if ! grep -q "$INSTALL_DIR/tools" /etc/profile.d/rk3588-toolkit.sh 2>/dev/null; then
        echo "export PATH=\$PATH:$INSTALL_DIR/tools" > /etc/profile.d/rk3588-toolkit.sh
        print_ok "PATH 已配置 (/etc/profile.d/rk3588-toolkit.sh)"
        log_info "PATH 配置完成"
    fi
}

install_docs() {
    print_step "安装部署文档"

    if [ -d "${SCRIPT_DIR}/deploy/docs" ]; then
        cp -r "${SCRIPT_DIR}/deploy/docs" "$INSTALL_DIR/docs"
        print_ok "部署文档已安装 (中/英文)"
        log_info "文档复制完成"
    else
        print_warn "deploy/docs 目录不存在，跳过文档"
        log_warn "deploy/docs 目录不存在"
    fi
}

install_demos() {
    print_step "安装 Demo 示例"

    cp -r "${SCRIPT_DIR}/deploy_scripts/demo" "$INSTALL_DIR/demo" 2>/dev/null || {
        mkdir -p "$INSTALL_DIR/demo"
    }
    cp -r "${SCRIPT_DIR}/deploy_scripts/demo"/* "$INSTALL_DIR/demo/" 2>/dev/null || true

    if [ -f "$INSTALL_DIR/demo/run_yolov5_demo.sh" ]; then
        print_ok "YOLOv5 Demo 已安装"
        log_info "Demo 复制完成"
    else
        print_warn "Demo 脚本不存在"
        log_warn "run_yolov5_demo.sh 未找到"
    fi

    # Modbus Demo
    if [ -d "${SCRIPT_DIR}/deploy/examples/modbus_demo" ]; then
        mkdir -p "$INSTALL_DIR/demo/modbus"
        cp -r "${SCRIPT_DIR}/deploy/examples/modbus_demo"/* "$INSTALL_DIR/demo/modbus/"
        print_ok "Modbus Demo 已安装"
    fi
}

# ── 实时补丁（仅 full 模式）───────────────────────────────────────────────
install_realtime() {
    if has_component "engine"; then
        print_step "实时性补丁"
        if [ -d "${SCRIPT_DIR}/patches/preempt_rt" ]; then
            mkdir -p "$INSTALL_DIR/realtime"
            cp -r "${SCRIPT_DIR}/patches/preempt_rt"/* "$INSTALL_DIR/realtime/"
            print_ok "PREEMPT_RT 补丁已安装"
            log_info "实时补丁复制完成"
        else
            print_warn "PREEMPT_RT 补丁目录不存在"
            log_warn "patches/preempt_rt 不存在"
        fi
    fi
}

# ── 设置执行权限 ──────────────────────────────────────────────────────────
set_permissions() {
    print_step "设置文件权限"
    find "$INSTALL_DIR" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
    print_ok "所有 .sh 文件已设置执行权限"
    log_info "执行权限设置完成"
}

# ── 安装后验证 ────────────────────────────────────────────────────────────
run_post_verify() {
    print_step "安装后验证"

    local check_script="${INSTALL_DIR}/env_check/check_env.sh"
    if [ -f "$check_script" ]; then
        echo ""
        echo -e "  ${CYAN}正在运行环境检测 ...${NC}"
        echo ""

        # 运行环境检测，将输出同时写入日志
        bash "$check_script" 2>&1 | tee -a "$LOG_FILE" || true

        print_ok "环境检测完成"
        log_info "post-install 环境检测完成"
    else
        print_warn "未找到 check_env.sh，跳过自动验证"
        log_warn "check_env.sh 不存在 ($check_script)"
        echo "  可稍后手动运行:"
        echo "    sudo bash ${SCRIPT_DIR}/deploy_scripts/env_check/check_env.sh"
    fi
}

# ── 打印安装摘要 ──────────────────────────────────────────────────────────
print_summary() {
    local end_time
    end_time=$(date "+%Y-%m-%d %H:%M:%S")

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  ✅ 安装完成${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""

    cat << SUMMARY
┌───────────────────────────────────────────┐
│  RK3588 Industrial Toolkit 已就绪         │
├───────────────────────────────────────────┤
│  安装目录:  ${INSTALL_DIR}
│  安装模式:  ${INSTALL_MODE}
│  日志文件:  ${LOG_FILE}
│  开始时间:  ${START_TIME}
│  完成时间:  ${end_time}
│                                           │
SUMMARY

    if has_component "tools"; then
        cat << TOOLS_SUMMARY
│  环境检测:                                │
│    sudo bash ${INSTALL_DIR}/env_check/check_env.sh
│                                           │
TOOLS_SUMMARY
    fi

    if has_component "demos"; then
        cat << DEMOS_SUMMARY
│  运行 Demo:                               │
│    sudo bash ${INSTALL_DIR}/demo/run_yolov5_demo.sh
│                                           │
DEMOS_SUMMARY
    fi

    if has_component "tools"; then
        cat << CMD_SUMMARY
│  快捷命令:                                │
│    rk3588-diagnose    — 故障诊断           │
│    rk3588-bench       — 性能基准           │
│                                           │
CMD_SUMMARY
    fi

    if has_component "engine"; then
        cat << ENGINE_SUMMARY
│  推理引擎配置:                            │
│    ${INSTALL_DIR}/configs/engine.yaml
│                                           │
│  配置向导（重新生成配置）:                │
│    sudo bash ${SCRIPT_DIR}/deploy_scripts/oneclick/web_config.sh
│                                           │
ENGINE_SUMMARY
    fi

    echo "└───────────────────────────────────────────┘"
    echo ""

    # 日志
    cat >> "$LOG_FILE" << LOG_FOOTER

================================================================================
安装完成
结束时间: ${end_time}
安装模式: ${INSTALL_MODE}
安装组件: ${INSTALL_COMPONENTS}
安装目录: ${INSTALL_DIR}
================================================================================
LOG_FOOTER

    echo -e "  ${CYAN}📋 完整安装日志: ${LOG_FILE}${NC}"
}

# ═══════════════════════════════════════════════════════════════════════════
# main() — 主流程
# ═══════════════════════════════════════════════════════════════════════════
main() {
    # 解析参数
    parse_args "$@"

    # 初始化日志
    log_init

    # 打印 Banner
    print_banner

    # 架构检查
    check_arch
    echo ""

    # 交互菜单（仅在 interactive 模式下）
    if [ "$INSTALL_MODE" = "interactive" ]; then
        interactive_menu
    else
        echo -e "安装模式: ${GREEN}${INSTALL_MODE}${NC}"
        echo -e "安装组件: ${GREEN}$(echo $INSTALL_COMPONENTS | tr ' ' ', ')${NC}"
        echo ""
    fi

    # 备份旧版本
    backup_old

    # 创建目录结构
    create_dirs

    # 按需安装各组件
    has_component "engine"    && install_engine
    has_component "protocols" && install_protocols
    has_component "tools"     && install_tools
    has_component "docs"      && install_docs
    has_component "demos"     && install_demos

    # 实时补丁
    install_realtime

    # 设置权限
    set_permissions

    # 安装后验证
    run_post_verify

    # 打印摘要
    print_summary
}

main "$@"
