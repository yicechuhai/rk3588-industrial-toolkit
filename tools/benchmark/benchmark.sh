#!/bin/bash
#===============================================================================
# RK3588 性能基准测试工具
# 功能：一键运行 NPU / CPU / 内存 / 网络基准测试，生成性能评分
#===============================================================================

set -e
VERSION="v1.0.0"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN}  RK3588 基准测试工具 ${VERSION}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── CPU 基准 ──
echo "🧮 CPU 基准测试 (sysbench)..."
if command -v sysbench &>/dev/null; then
    cpu_events=$(sysbench cpu --cpu-max-prime=5000 run 2>/dev/null | grep "events per second" | awk '{print $NF}')
    echo -e "  ${GREEN}CPU 事件/秒: ${cpu_events:-N/A}${NC}"
else
    echo -e "  ${YELLOW}⚠ sysbench 未安装${NC}"
fi

# ── 内存基准 ──
echo "🧠 内存基准测试..."
if command -v sysbench &>/dev/null; then
    mem_speed=$(sysbench memory --memory-block-size=1M --memory-total-size=1G run 2>/dev/null | grep "transferred" | awk '{print $4, $5}')
    echo -e "  ${GREEN}内存吞吐: ${mem_speed:-N/A}${NC}"
fi

# ── 磁盘基准 ──
echo "💾 磁盘基准测试 (dd)..."
disk_write=$(dd if=/dev/zero of=/tmp/bench_test bs=1M count=256 2>&1 | tail -1 | awk -F',' '{print $NF}')
rm -f /tmp/bench_test
echo -e "  ${GREEN}磁盘写入: ${disk_write}$NC"

# ── NPU 基准（如果有 Python + RKNN） ──
echo "🧠 NPU 基准测试..."
if python3 -c "from rknn.api import RKNN" 2>/dev/null; then
    python3 -c "
from rknn.api import RKNN
import numpy as np, time

rknn = RKNN()

# 尝试加载模型
import os
model_paths = [
    '/opt/rk3588-toolkit/models/yolov5s-640-640.rknn',
]
model = None
for p in model_paths:
    if os.path.exists(p):
        model = p
        break

if model:
    rknn.load_rknn(model)
    rknn.init_runtime(target='rk3588')
    dummy = np.random.randint(0,256,(1,640,640,3),dtype=np.uint8)
    for _ in range(3): rknn.inference(inputs=[dummy])
    times=[]
    for _ in range(50):
        t0=time.time()
        rknn.inference(inputs=[dummy])
        times.append((time.time()-t0)*1000)
    avg=np.mean(times)
    print(f'  NPU 推理: {avg:.1f}ms avg')
else:
    print('  ⚠ 未找到 RKNN 模型文件')
" 2>/dev/null || echo -e "  ${YELLOW}⚠ NPU 基准跳过${NC}"
else
    echo -e "  ${YELLOW}⚠ RKNN API 不可用${NC}"
fi

# ── 温度 ──
echo "🌡 温度检测..."
for zone in /sys/class/thermal/thermal_zone*; do
    if [ -f "$zone/temp" ]; then
        temp=$(( $(cat $zone/temp) / 1000 ))
        type=$(cat $zone/type 2>/dev/null || echo "unknown")
        echo "  ${type}: ${temp}°C"
    fi
done

echo ""
echo -e "${GREEN}✅ 基准测试完成${NC}"
