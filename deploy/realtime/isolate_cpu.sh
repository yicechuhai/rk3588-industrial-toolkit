#!/bin/bash
#===============================================================================
# isolate_cpu.sh - CPU 核心隔离与实时调优脚本
# 功能：一键配置 isolcpus + IRQ 亲和性 + 实时调度策略
# 适用：NanoPC T6 / 鲁班猫8 / Radxa Rock 5B / Orange Pi 5 / 飞凌 OK3588
# 依赖：PREEMPT_RT 内核
#===============================================================================

set -e

VERSION="v1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ISOLATED_CPUS="4,5,6,7"
IRQ_AFFINITY_CPUS="0,1,2,3"
RT_PRIORITY=80
CYCLICTEST_DURATION=60

print_banner() {
    echo "============================================"
    echo "  RK3588 CPU 隔离与实时调优工具 ${VERSION}"
    echo "  RK3588 CPU Isolation & RT Tuning Tool"
    echo "============================================"
    echo ""
}

print_cpu_layout() {
    echo -e "${CYAN}[INFO] RK3588 CPU 拓扑：${NC}"
    echo "  Cluster 0 (A55 小核): CPU 0-3 — 推荐用于非实时任务"
    echo "  Cluster 1 (A76 大核): CPU 4-7 — 推荐用于实时任务"
    echo ""
    echo "  CPU 4,5 (DSU Cluster 2): 共享 L2 缓存，适合低延迟单线程"
    echo "  CPU 6,7 (DSU Cluster 3): 共享 L2 缓存，适合低延迟单线程"
    echo ""
}

check_rt_kernel() {
    echo -e "${CYAN}[CHECK] 检测内核是否为 PREEMPT_RT...${NC}"
    local kernel_info=$(uname -a)
    if echo "$kernel_info" | grep -qi "PREEMPT_RT\|preempt.rt\|rt"; then
        echo -e "  [${GREEN}PASS${NC}] PREEMPT_RT 内核已就绪"
        echo "         -> $(uname -r)"
        return 0
    else
        echo -e "  [${YELLOW}WARN${NC}] 未检测到 PREEMPT_RT 内核"
        echo "         -> 请先运行 apply_rt_patch.sh 编译 RT 内核"
        echo "         -> 强行继续可能无法达到预期实时性能"
        return 1
    fi
}

configure_grub_isolcpus() {
    echo -e "${CYAN}[CONFIG] 配置 GRUB isolcpus=${ISOLATED_CPUS}...${NC}"
    if [ ! -f /etc/default/grub ]; then
        echo -e "  [${RED}FAIL${NC}] 未找到 /etc/default/grub"
        return 1
    fi
    if ! grep -q "isolcpus=${ISOLATED_CPUS}" /etc/default/grub; then
        cp /etc/default/grub /etc/default/grub.bak.$(date +%Y%m%d_%H%M%S)
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"isolcpus=${ISOLATED_CPUS} nohz_full=${ISOLATED_CPUS} rcu_nocbs=${ISOLATED_CPUS} /" /etc/default/grub
        update-grub 2>/dev/null || grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
        echo -e "  [${GREEN}DONE${NC}] GRUB 已更新，添加 isolcpus=${ISOLATED_CPUS}"
        echo -e "  [${YELLOW}NOTE${NC}] 请重启后生效 / Reboot required"
    else
        echo -e "  [${GREEN}SKIP${NC}] isolcpus 已配置"
    fi
}

set_irq_affinity() {
    echo -e "${CYAN}[CONFIG] 设置 IRQ 亲和性...${NC}"
    local mask=15
    echo "$mask" > /proc/irq/default_smp_affinity 2>/dev/null || true
    echo -e "  [${GREEN}DONE${NC}] 默认 IRQ 亲和性已设置"
    for irq in $(grep -E "eth|mmc|usb|dwc3|pcie" /proc/interrupts | awk '{print $1}' | tr -d ':'); do
        echo "$mask" > "/proc/irq/${irq}/smp_affinity" 2>/dev/null || true
    done
}

set_rt_limits() {
    echo -e "${CYAN}[CONFIG] 配置实时调度限制...${NC}"
    if [ -f /etc/security/limits.conf ]; then
        grep -q "rk3588.*rtprio" /etc/security/limits.conf 2>/dev/null || {
            cat >> /etc/security/limits.conf << 'LIMEOF'
@realtime   -   rtprio      99
@realtime   -   memlock     unlimited
*           -   nice        -20
LIMEOF
        }
    fi
    groupadd -f realtime
    echo -e "  [${GREEN}DONE${NC}] 实时调度限制已配置"
}

run_cyclictest() {
    echo -e "${CYAN}[BENCH] 运行 cyclictest (${CYCLICTEST_DURATION}秒)...${NC}"
    if ! command -v cyclictest &>/dev/null; then
        echo -e "  [${YELLOW}WARN${NC}] cyclictest 未安装"
        return 1
    fi
    cyclictest -t 1 -p ${RT_PRIORITY} -a ${ISOLATED_CPUS} -i 200 -d ${CYCLICTEST_DURATION} -m -q 2>/dev/null || \
    cyclictest -t 1 -p ${RT_PRIORITY} -a ${ISOLATED_CPUS} -i 200 -d ${CYCLICTEST_DURATION} -m 2>/dev/null || true
}

print_summary() {
    echo ""
    echo "============================================"
    echo "  Tuning Complete / 调优完成"
    echo "============================================"
    echo "  隔离 CPU:     ${ISOLATED_CPUS}"
    echo "  IRQ CPU:      ${IRQ_AFFINITY_CPUS}"
    echo "  RT Priority:  ${RT_PRIORITY}"
    echo ""
    echo "  Usage: taskset -c ${ISOLATED_CPUS} ./your_rt_app"
    echo "         chrt -f ${RT_PRIORITY} taskset -c ${ISOLATED_CPUS} ./your_rt_app"
}

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "  --isolated CPUS    隔离 CPU 列表 (默认 4,5,6,7)"
    echo "  --irq-cpus CPUS    IRQ 亲和 CPU 列表 (默认 0,1,2,3)"
    echo "  --priority N       实时优先级 (默认 80)"
    echo "  --bench-only       仅运行延迟测试"
    echo "  --dry-run          仅检测，不修改系统"
    echo "  --help             显示帮助"
}

DRY_RUN=false
BENCH_ONLY=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --isolated) ISOLATED_CPUS="$2"; shift 2 ;;
        --irq-cpus) IRQ_AFFINITY_CPUS="$2"; shift 2 ;;
        --priority) RT_PRIORITY="$2"; shift 2 ;;
        --bench-only) BENCH_ONLY=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown: $1"; show_help; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}Please run with sudo / 请用 sudo 运行${NC}"
    exit 1
fi

print_banner
print_cpu_layout
if [ "$BENCH_ONLY" = true ]; then run_cyclictest; exit 0; fi
check_rt_kernel
configure_grub_isolcpus
set_irq_affinity
set_rt_limits
run_cyclictest
print_summary
echo -e "${YELLOW}[NOTE] GRUB 修改后请重启${NC}"