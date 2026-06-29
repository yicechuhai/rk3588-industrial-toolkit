#!/bin/bash
#===============================================================================
# check_npu_driver.sh — RK3588 NPU Driver & RKNN Runtime Version Checker
# 功能：检测 NPU 驱动版本和 RKNN Runtime 版本，检查版本兼容性
# 兼容：NanoPC T6 / 鲁班猫8 / Radxa Rock 5B / Orange Pi 5 / 飞凌 OK3588
#===============================================================================

set -e

VERSION="v1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
DETECTED_DRIVER_VER=""
DETECTED_RUNTIME_VER=""
DETECTED_TOOLKIT_VER=""

#===============================================================================
# 版本兼容性矩阵
# 来源：GitHub airockchip/rknn-toolkit2 releases + community verified
# 更新：2026-06-21
#===============================================================================
declare -A COMPAT_MATRIX=(
    ["2.3.2"]="0.9.8"
    ["2.2.0"]="0.9.6"
    ["2.1.0"]="0.9.2"
    ["2.0.0"]="0.8.8"
    ["1.6.0"]="0.8.2"
)

declare -A COMPAT_DESC=(
    ["2.3.2"]="最新版，推荐"
    ["2.2.0"]="稳定版"
    ["2.1.0"]="旧版"
    ["2.0.0"]="旧版，不推荐"
    ["1.6.0"]="已弃用，不推荐"
)

#===============================================================================
# 辅助函数
#===============================================================================
print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "  RK3588 NPU Driver & Runtime"
    echo "  Version Compatibility Checker ${VERSION}"
    echo "============================================"
    echo -e "${NC}"
}

print_result() {
    local status=$1
    local item=$2
    local detail=$3
    local suggestion=$4

    if [ "$status" = "PASS" ]; then
        echo -e "  [${GREEN}PASS${NC}] ${item}"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ "$status" = "WARN" ]; then
        echo -e "  [${YELLOW}WARN${NC}] ${item}"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo -e "  [${RED}FAIL${NC}] ${item}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    echo "         → ${detail}"
    [ -n "$suggestion" ] && echo "         → 建议：${suggestion}"
}

version_compare() {
    # 返回值：0=相等, 1=左>右, 2=左<右
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
# 1. 检测 NPU 硬件设备
#===============================================================================
check_npu_device() {
    echo -e "${CYAN}━━━ 1. NPU 硬件设备检测 ━━━${NC}"

    # 1.1 检测设备节点（多种路径兼容）
    local found=false
    for node in /dev/dri/renderD128 /dev/misc/rknpu /dev/rknpu; do
        if [ -e "$node" ]; then
            print_result "PASS" "NPU 设备节点" "找到: ${node}"
            found=true
            break
        fi
    done

    if [ "$found" = false ]; then
        print_result "FAIL" "NPU 设备节点" "未找到 NPU 设备节点" \
            "请确认 NPU 驱动已加载。运行: lsmod | grep rknpu"
    fi

    # 1.2 检测内核模块
    if lsmod 2>/dev/null | grep -q "rknpu"; then
        local mod_info=$(lsmod | grep "rknpu" | awk '{print $1, $2, $3}')
        print_result "PASS" "NPU 内核模块" "已加载: ${mod_info}"
    else
        print_result "FAIL" "NPU 内核模块" "rknpu 模块未加载" \
            "运行: sudo modprobe rknpu"
    fi

    # 1.3 检测 NPU 温度
    for temp_node in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$temp_node" ]; then
            local name=$(cat "$(dirname "$temp_node")/type" 2>/dev/null || echo "")
            if echo "$name" | grep -qi "rknpu\|npu"; then
                local temp=$(cat "$temp_node")
                local temp_c=$((temp / 1000))
                if [ "$temp_c" -le 80 ]; then
                    print_result "PASS" "NPU 温度" "${temp_c}°C"
                else
                    print_result "WARN" "NPU 温度" "${temp_c}°C (偏高)"
                fi
                break
            fi
        fi
    done
}

#===============================================================================
# 2. 检测 NPU 驱动版本
#===============================================================================
check_driver_version() {
    echo ""
    echo -e "${CYAN}━━━ 2. NPU 驱动版本检测 ━━━${NC}"

    local driver_ver=""
    local driver_source=""

    # 2.1 通过 debugfs 检测（最可靠）
    if [ -f /sys/kernel/debug/rknpu/version ]; then
        driver_ver=$(cat /sys/kernel/debug/rknpu/version 2>/dev/null | head -1)
        driver_source="debugfs"
    fi

    # 2.2 通过 dmesg 检测（debugfs 不可用时）
    if [ -z "$driver_ver" ]; then
        local dmesg_line=$(dmesg 2>/dev/null | grep -i "rknpu" | grep -i "version" | tail -1 || true)
        if [ -n "$dmesg_line" ]; then
            driver_ver=$(echo "$dmesg_line" | grep -oP 'v?\d+\.\d+\.\d+' | head -1 || echo "")
            driver_source="dmesg"
        fi
    fi

    # 2.3 通过模块信息检测
    if [ -z "$driver_ver" ]; then
        local modinfo_line=$(modinfo rknpu 2>/dev/null | grep "^version:" || true)
        if [ -n "$modinfo_line" ]; then
            driver_ver=$(echo "$modinfo_line" | awk '{print $2}')
            driver_source="modinfo"
        fi
    fi

    if [ -n "$driver_ver" ]; then
        # 标准化版本号格式：去掉"v"前缀，只保留 x.y.z
        driver_ver=$(echo "$driver_ver" | sed 's/^v//' | grep -oP '\d+\.\d+\.\d+' | head -1)
        DETECTED_DRIVER_VER="$driver_ver"

        # 检查是否 >= 0.9.8（推荐版本）
        local min_ver="0.9.8"
        version_compare "$driver_ver" "$min_ver"
        local cmp_result=$?

        if [ "$cmp_result" = 0 ] || [ "$cmp_result" = 1 ]; then
            print_result "PASS" "NPU 驱动版本" \
                "v${driver_ver} (来源: ${driver_source}) ✓ 满足 ≥ v${min_ver} 要求"
        else
            print_result "WARN" "NPU 驱动版本" \
                "v${driver_ver} (来源: ${driver_source})" \
                "推荐升级到 v${min_ver}+。运行: sudo bash upgrade_npu_driver.sh"
        fi
    else
        print_result "FAIL" "NPU 驱动版本" "无法检测到 NPU 驱动版本" \
            "请确认 NPU 驱动已正确安装并加载"
    fi
}

#===============================================================================
# 3. 检测 RKNN Runtime 版本
#===============================================================================
check_runtime_version() {
    echo ""
    echo -e "${CYAN}━━━ 3. RKNN Runtime 版本检测 ━━━${NC}"

    local runtime_ver=""
    local runtime_path=""

    # 3.1 查找 librknnrt.so 位置
    for libpath in /usr/lib/librknnrt.so /usr/lib64/librknnrt.so /usr/local/lib/librknnrt.so; do
        if [ -f "$libpath" ]; then
            runtime_path="$libpath"
            break
        fi
    done

    if [ -z "$runtime_path" ]; then
        # 通过 ldconfig 查找
        runtime_path=$(ldconfig -p 2>/dev/null | grep "librknnrt.so" | awk '{print $NF}' | head -1 || true)
    fi

    if [ -n "$runtime_path" ] && [ -f "$runtime_path" ]; then
        # 尝试从版本符号中提取版本号
        if command -v strings &>/dev/null; then
            runtime_ver=$(strings "$runtime_path" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        fi

        # 尝试通过 dpkg 获取版本
        if [ -z "$runtime_ver" ]; then
            runtime_ver=$(dpkg -l 2>/dev/null | grep "rknn" | awk '{print $3}' | head -1 || true)
        fi

        if [ -n "$runtime_ver" ]; then
            DETECTED_RUNTIME_VER="$runtime_ver"
            print_result "PASS" "RKNN Runtime 库" \
                "路径: ${runtime_path}, 版本: ${runtime_ver}"
        else
            print_result "WARN" "RKNN Runtime 库" \
                "路径: ${runtime_path}, 但无法提取版本号" \
                "运行: dpkg -l | grep rknn"
        fi
    else
        # 检查是否有 pip 安装的 rknn 工具
        if python3 -c "import rknn" 2>/dev/null; then
            runtime_ver=$(python3 -c "import rknn; print(getattr(rknn, '__version__', 'unknown'))" 2>/dev/null || echo "unknown")
            print_result "WARN" "RKNN Runtime (Python)" \
                "检测到 Python 安装: ${runtime_ver}, 但未找到 librknnrt.so" \
                "安装 C++ Runtime: sudo bash upgrade_npu_driver.sh"
        else
            print_result "FAIL" "RKNN Runtime 库" \
                "未找到 librknnrt.so" \
                "运行: sudo bash upgrade_npu_driver.sh 自动安装"
        fi
    fi
}

#===============================================================================
# 4. 检查版本兼容性
#===============================================================================
check_compatibility() {
    echo ""
    echo -e "${CYAN}━━━ 4. 版本兼容性检查 ━━━${NC}"

    if [ -z "$DETECTED_DRIVER_VER" ]; then
        print_result "FAIL" "版本兼容性" "无法检查：NPU 驱动版本未知"
        return
    fi

    # 查找匹配的 Toolkit 版本
    local matched_toolkit=""
    local matched_driver=""

    for tk_ver in "${!COMPAT_MATRIX[@]}"; do
        local required_driver="${COMPAT_MATRIX[$tk_ver]}"
        if [ "$DETECTED_DRIVER_VER" = "$required_driver" ]; then
            matched_toolkit="$tk_ver"
            matched_driver="$required_driver"
            break
        fi
    done

    if [ -n "$matched_toolkit" ]; then
        print_result "PASS" "驱动版本兼容性" \
            "驱动 v${DETECTED_DRIVER_VER} ↔ RKNN-Toolkit ${matched_toolkit} ✓ (${COMPAT_DESC[$matched_toolkit]:-稳定})"
    else
        # 显示最接近的推荐版本
        local recommended_driver="${COMPAT_MATRIX["2.3.2"]}"
        version_compare "$DETECTED_DRIVER_VER" "$recommended_driver"
        local cmp_result=$?

        if [ "$cmp_result" = 2 ]; then
            # 当前驱动版本低于推荐版本
            print_result "WARN" "驱动版本兼容性" \
                "当前驱动 v${DETECTED_DRIVER_VER} 不在已知兼容列表中" \
                "推荐升级到 v${recommended_driver} 以兼容 RKNN-Toolkit 2.3.2"
        else
            print_result "WARN" "驱动版本兼容性" \
                "当前驱动 v${DETECTED_DRIVER_VER} 不在已知兼容列表中" \
                "请确认版本对应关系"
        fi
    fi

    # 完整兼容性表
    echo ""
    echo "  已知兼容版本对应关系:"
    echo "  ┌─────────────────┬─────────────────┐"
    echo "  │ RKNN-Toolkit2   │ NPU 驱动版本    │"
    echo "  ├─────────────────┼─────────────────┤"
    for tk_ver in 2.3.2 2.2.0 2.1.0 2.0.0 1.6.0; do
        local drv="${COMPAT_MATRIX[$tk_ver]}"
        local desc="${COMPAT_DESC[$tk_ver]}"
        local marker="  "
        if [ "$drv" = "$DETECTED_DRIVER_VER" ]; then
            marker="→"
        fi
        printf "  │ %s %-15s │ %-15s │\n" "$marker" "$tk_ver" "$drv"
    done
    echo "  └─────────────────┴─────────────────┘"

    # 检查 RKNN Toolkit2 是否安装
    if pip3 list 2>/dev/null | grep -q "rknn-toolkit"; then
        local tk_ver=$(pip3 show rknn-toolkit-lite2 2>/dev/null | grep "^Version:" | awk '{print $2}' || \
                       pip3 show rknn-toolkit2 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
        DETECTED_TOOLKIT_VER="$tk_ver"
        print_result "PASS" "RKNN-Toolkit (Python)" "版本: ${tk_ver}"
    else
        print_result "WARN" "RKNN-Toolkit (Python)" "未安装 (仅 PC 端模型转换需要)"
    fi
}

#===============================================================================
# 5. 检查 rknn_server 状态
#===============================================================================
check_rknn_server() {
    echo ""
    echo -e "${CYAN}━━━ 5. rknn_server 状态检测 ━━━${NC}"

    # 5.1 进程检测
    if pgrep -x "rknn_server" > /dev/null 2>&1; then
        local pid=$(pgrep -x "rknn_server")
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | xargs || echo "unknown")
        print_result "PASS" "rknn_server 进程" "运行中 (PID: ${pid}, 运行时间: ${uptime})"
    else
        print_result "WARN" "rknn_server 进程" "未运行 (仅 Python API 需要, C++ API 不需要)"
    fi

    # 5.2 启动脚本检测
    if [ -f /usr/bin/start_rknn.sh ]; then
        print_result "PASS" "rknn_server 启动脚本" "存在: /usr/bin/start_rknn.sh"
    else
        print_result "WARN" "rknn_server 启动脚本" "未找到 (不在预期路径, 可能在其他位置)"
    fi
}

#===============================================================================
# 6. 环境诊断（快速检查常见问题）
#===============================================================================
check_common_issues() {
    echo ""
    echo -e "${CYAN}━━━ 6. 常见问题快速诊断 ━━━${NC}"

    # 6.1 检查 debugfs 挂载
    if mount | grep -q "debugfs"; then
        print_result "PASS" "debugfs 挂载" "已挂载"
    else
        print_result "WARN" "debugfs 挂载" "未挂载 (会影响驱动版本读取)" \
            "运行: sudo mount -t debugfs none /sys/kernel/debug"
    fi

    # 6.2 检查 RKNN 内存限制
    if [ -f /proc/sys/vm/min_free_kbytes ]; then
        local min_free=$(cat /proc/sys/vm/min_free_kbytes)
        if [ "$min_free" -ge 65536 ]; then
            print_result "PASS" "内存保留" "min_free_kbytes=${min_free}KB ✓"
        else
            print_result "WARN" "内存保留" "min_free_kbytes=${min_free}KB (< 64MB, NPU 大模型推理可能 OOM)" \
                "运行: echo 65536 | sudo tee /proc/sys/vm/min_free_kbytes"
        fi
    fi

    # 6.3 检查 NPU 频率
    for gov in /sys/class/devfreq/fdab0000.npu/cur_freq /sys/class/devfreq/*npu*/cur_freq; do
        if [ -f "$gov" ]; then
            local freq=$(cat "$gov" 2>/dev/null)
            local freq_mhz=$((freq / 1000000))
            print_result "PASS" "NPU 运行频率" "${freq_mhz}MHz"
            break
        fi
    done
}

#===============================================================================
# 主函数
#===============================================================================
main() {
    print_banner

    # 检测是否在 RK3588 上运行
    local arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        echo -e "${YELLOW}⚠ 警告：当前架构为 ${arch}，此脚本专为 RK3588 (ARM64) 设计${NC}"
        echo "   部分检测项可能不适用。"
        echo ""
    fi

    check_npu_device
    check_driver_version
    check_runtime_version
    check_compatibility
    check_rknn_server
    check_common_issues

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  检测完成"
    echo "  ✅ 通过: ${PASS_COUNT}"
    echo "  ⚠️  警告: ${WARN_COUNT}"
    echo "  ❌ 失败: ${FAIL_COUNT}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "${RED}⚠ 检测到 ${FAIL_COUNT} 个问题。${NC}"
        echo "   运行以下命令尝试自动修复:"
        echo "   sudo bash upgrade_npu_driver.sh"
    elif [ "$WARN_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}ℹ 有 ${WARN_COUNT} 个警告项，建议按需处理。${NC}"
    else
        echo -e "${GREEN}✅ NPU 环境一切正常！${NC}"
    fi

    echo ""
    echo -e "${CYAN}━ 版本摘要 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  NPU 驱动:    ${DETECTED_DRIVER_VER:-未检测到}"
    echo "  RKNN Runtime: ${DETECTED_RUNTIME_VER:-未检测到}"
    echo "  RKNN Toolkit: ${DETECTED_TOOLKIT_VER:-未安装}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    return $FAIL_COUNT
}

main
