#!/bin/bash
#===============================================================================
# RK3588 故障诊断工具
# 功能：快速定位常见部署问题，输出排查指引
#===============================================================================

set -e

VERSION="v1.0.0"
ISSUE_COUNT=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

banner() {
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}  RK3588 故障诊断工具 ${VERSION}${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo ""
}

# 诊断1: NPU 设备节点缺失
check_npu_device() {
    echo "🔍 检查 NPU 设备..."
    if [ ! -e /dev/dri/renderD128 ]; then
        echo -e "  ${RED}❌ /dev/dri/renderD128 不存在${NC}"
        echo "  ⚠ 可能原因："
        echo "    1. 未安装 NPU 驱动 → 运行 patches/npu_driver/ 下的补丁脚本"
        echo "    2. 内核未启用 ROCKCHIP_RKNPU → 检查内核配置"
        echo "    3. 用户组权限不足 → sudo usermod -aG render $USER"
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    else
        echo -e "  ${GREEN}✅ NPU 设备就绪${NC}"
    fi
}

# 诊断2: librknnrt.so 缺失
check_rknn_runtime() {
    echo "🔍 检查 RKNN Runtime..."
    if ! ldconfig -p | grep -q librknnrt; then
        echo -e "  ${RED}❌ librknnrt.so 未找到${NC}"
        echo "  ⚠ 修复方法："
        echo "    1. 下载 RKNN Runtime：https://github.com/airockchip/rknn-toolkit2/releases"
        echo "    2. sudo dpkg -i rknn_runtime_*.deb"
        echo "    3. 或运行 deploy_scripts/demo/run_yolov5_demo.sh（会自动安装）"
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    else
        echo -e "  ${GREEN}✅ RKNN Runtime 已安装${NC}"
    fi
}

# 诊断3: RGA 设备
check_rga() {
    echo "🔍 检查 RGA 加速..."
    if [ ! -e /dev/rga ]; then
        echo -e "  ${YELLOW}⚠ /dev/rga 不存在${NC}"
        echo "  ⚠ 零拷贝流水线将退化为 CPU 模式"
    else
        echo -e "  ${GREEN}✅ RGA 就绪${NC}"
    fi
}

# 诊断4: 摄像头设备
check_camera() {
    echo "🔍 检查摄像头..."
    local cam_found=false
    for dev in /dev/video*; do
        if [ -e "$dev" ]; then
            local name=$(cat /sys/class/video4linux/$(basename $dev)/name 2>/dev/null || echo "unknown")
            echo -e "  ${GREEN}✅ $dev - $name${NC}"
            cam_found=true
        fi
    done
    if ! $cam_found; then
        echo -e "  ${YELLOW}⚠ 未检测到摄像头设备${NC}"
        echo "  ⚠ 可使用图片模式测试推理"
    fi
}

# 诊断5: 内核实时性
check_realtime() {
    echo "🔍 检查实时补丁..."
    if uname -r | grep -q "rt"; then
        echo -e "  ${GREEN}✅ 当前运行 PREEMPT_RT 内核${NC}"
    else
        echo -e "  ${YELLOW}⚠ 当前为通用内核${NC}"
        echo "  ⚠ 建议：运行 deploy/realtime/ 下的 PREEMPT_RT 补丁脚本"
    fi
    
    # 检查内核抢占模型
    local preempt=$(cat /sys/kernel/realtime 2>/dev/null || echo "0")
    if [ "$preempt" = "1" ]; then
        echo -e "  ${GREEN}✅ 内核抢占模型: RT${NC}"
    fi
}

# 诊断6: 内存预留
check_memory() {
    echo "🔍 检查内存..."
    local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_mem_mb=$((total_mem_kb / 1024))
    if [ "$total_mem_mb" -lt 4096 ]; then
        echo -e "  ${RED}❌ 内存不足: ${total_mem_mb}MB (需 >= 4GB)${NC}"
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    else
        echo -e "  ${GREEN}✅ 内存充足: ${total_mem_mb}MB${NC}"
    fi
    
    # CMA 内存
    local cma=$(cat /proc/meminfo | grep CmaTotal | awk '{print $2}')
    if [ -n "$cma" ] && [ "$cma" -lt 262144 ]; then
        echo -e "  ${YELLOW}⚠ CMA 内存较小: ${cma}KB${NC}"
    fi
}

# 诊断7: Python 环境
check_python() {
    echo "🔍 检查 Python..."
    if command -v python3 &>/dev/null; then
        local pyver=$(python3 --version)
        echo -e "  ${GREEN}✅ $pyver${NC}"
    else
        echo -e "  ${RED}❌ python3 未安装${NC}"
        ISSUE_COUNT=$((ISSUE_COUNT + 1))
    fi
    
    for pkg in numpy opencv-python; do
        python3 -c "import ${pkg%%-*}" 2>/dev/null && \
            echo -e "  ${GREEN}✅ $pkg${NC}" || \
            echo -e "  ${YELLOW}⚠ $pkg 未安装${NC}"
    done
}

main() {
    banner
    check_npu_device
    check_rknn_runtime
    check_rga
    check_camera
    check_realtime
    check_memory
    check_python
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$ISSUE_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✅ 未发现严重问题${NC}"
    else
        echo -e "${RED}⚠ 发现 $ISSUE_COUNT 个需要修复的问题${NC}"
        echo ""
        echo "💡 常见修复入口："
        echo "  • NPU 驱动安装: bash patches/npu_driver/install.sh"
        echo "  • 实时补丁编译: bash deploy/realtime/patch_kernel.sh"
        echo "  • 环境一键检测: sudo bash deploy_scripts/env_check/check_env.sh"
        echo "  • 在线帮助: https://github.com/yicechuhai/rk3588-industrial-toolkit/issues"
    fi
}

main "$@"
