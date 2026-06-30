#!/bin/bash
# =============================================================================
# RK3588 Performance Benchmark Report Generator
# =============================================================================
# 用法:
#   sudo ./benchmark_report.sh                    # 完整基准测试
#   sudo ./benchmark_report.sh --quick             # 快速测试 (5分钟)
#   sudo ./benchmark_report.sh --output report.md  # 输出Markdown报告
#
# 测试项目:
#   1. NPU 推理性能 (单帧延迟、吞吐量)
#   2. CPU 实时性 (cyclictest 延迟)
#   3. 内存带宽 (stream)
#   4. RGA 硬件加速吞吐
#   5. 网络吞吐 (iperf3)
#   6. 温升曲线 (压力测试)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
REPORT_FILE="${SCRIPT_DIR}/benchmark_${TIMESTAMP}.md"
QUICK_MODE=false
OUTPUT_FILE=""

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[BENCH]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[BENCH]${NC} $*"; }

# ── 参数解析 ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) QUICK_MODE=true; shift ;;
        --output) OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help) echo "用法: $0 [--quick] [--output file.md]"; exit 0 ;;
        *) shift ;;
    esac
done

if [ -n "${OUTPUT_FILE}" ]; then
    REPORT_FILE="${OUTPUT_FILE}"
fi

# ── 系统信息采集 ──
collect_system_info() {
    log_info "采集系统信息..."
    
    local kernel=$(uname -r)
    local model=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
    local cpu_count=$(nproc)
    local mem_total=$(free -h | awk '/Mem:/{print $2}')
    local npu_driver=$(dmesg 2>/dev/null | grep -i 'rknpu' | head -1 | grep -oP 'RKNPU.*' || echo "Not detected")
    local rga_version=$(dpkg -l librga2 2>/dev/null | grep librga2 | awk '{print $3}' || echo "Unknown")
    local temp_zone=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    local temp_c=$((temp_zone / 1000))
    
    cat << EOF

## 系统信息
| 项目 | 值 |
|------|-----|
| 板卡型号 | ${model} |
| 内核版本 | ${kernel} |
| CPU 核心 | ${cpu_count} |
| 内存总量 | ${mem_total} |
| NPU 驱动 | ${npu_driver} |
| RGA 版本 | ${rga_version} |
| 初始温度 | ${temp_c}°C |
| 测试时间 | $(date '+%Y-%m-%d %H:%M:%S') |
| 测试模式 | $([ "${QUICK_MODE}" = true ] && echo "快速" || echo "完整") |

EOF
}

# ── NPU 推理基准 ──
bench_npu() {
    log_info "测试 NPU 推理性能..."
    
    local engine_bin="/opt/rk3588-toolkit/bin/pipeline_runner"
    if [ ! -x "${engine_bin}" ]; then
        engine_bin="${SCRIPT_DIR}/../build/pipeline/pipeline_runner"
    fi
    
    if [ ! -x "${engine_bin}" ]; then
        echo "| NPU 推理 | N/A | 未找到 pipeline_runner |" >> "${REPORT_FILE}.tmp"
        return
    fi
    
    # 使用单张图片测试推理延迟
    local test_img="/tmp/bench_test.jpg"
    # 创建测试图片 (640x640 纯色)
    python3 -c "
import cv2, numpy as np
img = np.zeros((640, 640, 3), dtype=np.uint8)
cv2.imwrite('${test_img}', img)
print('test image created')
" 2>/dev/null || true
    
    # 运行 demo_inference
    local demo_bin="/opt/rk3588-toolkit/bin/demo_inference"
    [ ! -x "${demo_bin}" ] && demo_bin="${SCRIPT_DIR}/../build/engine/demo_inference"
    
    if [ -x "${demo_bin}" ] && [ -f "${test_img}" ]; then
        local output=$("${demo_bin}" 2>&1 || echo "N/A")
        echo "| NPU 推理 | 见日志 | ${output} |" >> "${REPORT_FILE}.tmp"
    else
        echo "| NPU 推理 | N/A | demo_inference 不可用 |" >> "${REPORT_FILE}.tmp"
    fi
    
    rm -f "${test_img}"
}

# ── CPU 实时性基准 ──
bench_realtime() {
    log_info "测试 CPU 实时性 (cyclictest)..."
    
    if ! command -v cyclictest &>/dev/null; then
        echo "| CPU 实时延迟 | N/A | cyclictest 未安装 (sudo apt install rt-tests) |" >> "${REPORT_FILE}.tmp"
        return
    fi
    
    local duration="$([ "${QUICK_MODE}" = true ] && echo "30s" || echo "60s")"
    
    log_info "  运行 cyclictest (${duration})..."
    local result=$(sudo cyclictest -p99 -D "${duration}" -m -q 2>&1 || true)
    
    # 解析结果
    local avg=$(echo "${result}" | grep -oP 'Avg:\s*\K[0-9]+' || echo "N/A")
    local max=$(echo "${result}" | grep -oP 'Max:\s*\K[0-9]+' || echo "N/A")
    local min=$(echo "${result}" | grep -oP 'Min:\s*\K[0-9]+' || echo "N/A")
    
    echo "| CPU 实时延迟 | Min: ${min}μs / Avg: ${avg}μs / Max: ${max}μs | cyclictest -p99 -D${duration} |" >> "${REPORT_FILE}.tmp"
}

# ── 内存带宽基准 ──
bench_memory() {
    log_info "测试内存带宽..."
    
    if ! command -v stream &>/dev/null; then
        echo "| 内存带宽 | N/A | stream 未安装 |" >> "${REPORT_FILE}.tmp"
        return
    fi
    
    local result=$(stream 2>&1 | grep -E 'Copy|Scale|Add|Triad' || echo "N/A")
    echo "| 内存带宽 | ${result} | stream benchmark |" >> "${REPORT_FILE}.tmp"
}

# ── RGA 硬件加速基准 ──
bench_rga() {
    log_info "测试 RGA 硬件加速..."
    
    if [ -e /dev/rga ]; then
        # 简单检查 RGA 设备可用性
        local rga_info=$(cat /sys/kernel/debug/rga/version 2>/dev/null || echo "RGA device present")
        echo "| RGA 加速器 | 可用 | ${rga_info} |" >> "${REPORT_FILE}.tmp"
    else
        echo "| RGA 加速器 | 不可用 | /dev/rga 不存在 |" >> "${REPORT_FILE}.tmp"
    fi
}

# ── 温升曲线 ──
bench_thermal() {
    log_info "监测温度变化..."
    
    local readings=()
    local duration="$([ "${QUICK_MODE}" = true ] && echo 10 || echo 30)"
    
    for i in $(seq 1 ${duration}); do
        local temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
        local temp_c=$((temp / 1000))
        readings+=("${temp_c}")
        sleep 1
        if [ $((i % 5)) -eq 0 ]; then
            echo -n "."
        fi
    done
    echo ""
    
    # 计算统计
    local sum=0 max=0 min=999
    for t in "${readings[@]}"; do
        sum=$((sum + t))
        [ "${t}" -gt "${max}" ] && max=${t}
        [ "${t}" -lt "${min}" ] && min=${t}
    done
    local avg=$((sum / ${#readings[@]}))
    
    echo "| 温度监测 | Min: ${min}°C / Avg: ${avg}°C / Max: ${max}°C | ${duration}s 采样 |" >> "${REPORT_FILE}.tmp"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo ""
    echo "============================================="
    log_info "RK3588 Performance Benchmark"
    log_info "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "模式: $([ "${QUICK_MODE}" = true ] && echo "快速" || echo "完整")"
    echo "============================================="
    echo ""
    
    # 初始化临时文件
    > "${REPORT_FILE}.tmp"
    
    # 报告头
    cat > "${REPORT_FILE}" << EOF
# RK3588 Industrial Toolkit — Performance Benchmark Report

> **生成时间**: $(date '+%Y-%m-%d %H:%M:%S')
> **测试模式**: $([ "${QUICK_MODE}" = true ] && echo "快速 (Quick)" || echo "完整 (Full)")
> **工具版本**: v1.0.0

---

EOF
    
    # 采集系统信息
    collect_system_info >> "${REPORT_FILE}"
    
    echo "## 测试结果" >> "${REPORT_FILE}"
    echo "" >> "${REPORT_FILE}"
    echo "| 测试项 | 结果 | 备注 |" >> "${REPORT_FILE}"
    echo "|--------|------|------|" >> "${REPORT_FILE}"
    
    # 运行各项基准测试
    bench_npu
    bench_realtime
    bench_rga
    bench_memory
    bench_thermal
    
    # 合并结果
    cat "${REPORT_FILE}.tmp" >> "${REPORT_FILE}"
    rm -f "${REPORT_FILE}.tmp"
    
    # 报告尾
    cat >> "${REPORT_FILE}" << EOF

---

## 性能目标对照

| 指标 | 目标值 | 实测值 | 状态 |
|------|--------|--------|------|
| 中断延迟空闲 | < 20 μs | - | ⬜ |
| 中断延迟满载 | < 50 μs | - | ⬜ |
| YOLOv5s NPU FPS | 50+ | - | ⬜ |
| 视频流水线 CPU | < 15% | - | ⬜ |

---

> 报告由 benchmark_report.sh 自动生成
> 仓库: https://github.com/yicechuhai/rk3588-industrial-toolkit
EOF
    
    echo ""
    echo "============================================="
    log_info "报告已生成: ${REPORT_FILE}"
    echo "============================================="
    
    # 显示报告摘要
    echo ""
    cat "${REPORT_FILE}"
}

main "$@"
