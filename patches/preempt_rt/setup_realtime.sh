#!/bin/bash
#===============================================================================
# setup_realtime.sh - RK3588 Realtime Tuning Configuration Tool
# Function: CPU isolation + IRQ affinity binding + cyclictest latency validation
# Compatible: NanoPC T6 (Debian 11, PREEMPT_RT kernel)
# Dependencies: rt-tests (cyclictest), stress-ng (optional, for stress test)
#===============================================================================

set -e

VERSION="v1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

#===============================================================================
# Global configuration
#===============================================================================
# Realtime-dedicated cores (RK3588: cores 4-7 are high-performance)
RT_CPUS="4-7"
RT_CPUS_LIST="4,5,6,7"
# Non-realtime cores / IRQ handling cores
IRQ_CPUS="0-3"
IRQ_CPUS_LIST="0,1,2,3"

# cyclictest configuration
CYCLICTEST_DURATION=300
CYCLICTEST_PRIORITY=99
CYCLICTEST_INTERVAL=1000
CYCLICTEST_HISTOGRAM=50

#===============================================================================
# Helper functions
#===============================================================================
print_banner() {
    echo -e "${CYAN}"
    echo "============================================"
    echo "  RK3588 Realtime Tuning Tool"
    echo "  ${VERSION}"
    echo "============================================"
    echo -e "${NC}"
}

log_info()  { echo -e "  ${GREEN}INFO${NC}  $(date '+%H:%M:%S')  $*"; }
log_warn()  { echo -e "  ${YELLOW}WARN${NC}  $(date '+%H:%M:%S')  $*"; }
log_error() { echo -e "  ${RED}ERROR${NC} $(date '+%H:%M:%S')  $*" >&2; }

usage() {
    echo "Usage: sudo bash setup_realtime.sh [options]"
    echo ""
    echo "Options:"
    echo "  --check-only      Only check current realtime config"
    echo "  --apply           Apply realtime tuning config"
    echo "  --cyclictest      Run cyclictest latency test only"
    echo "  --stress          Run stress test (stress-ng + cyclictest)"
    echo "  --restore         Restore default configuration"
    echo "  --help, -h        Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo bash setup_realtime.sh --check-only    # Check only"
    echo "  sudo bash setup_realtime.sh --apply         # Apply tuning"
    echo "  sudo bash setup_realtime.sh --cyclictest    # Run latency test"
    echo "  sudo bash setup_realtime.sh --stress        # Full stress test"
    echo ""
    echo "Env vars:"
    echo "  CYCLICTEST_DURATION=300    Test duration in seconds"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root: sudo bash $0"
        exit 1
    fi
}

#===============================================================================
# System detection
#===============================================================================
check_prerequisites() {
    echo ""
    echo -e "${CYAN}--- 0. Pre-flight Check ---${NC}"

    local arch=$(uname -m)
    if [ "$arch" != "aarch64" ]; then
        log_error "Current architecture: ${arch}, this script only supports ARM64 (RK3588)"
        exit 1
    fi
    log_info "Architecture: ${arch} OK"

    if uname -a | grep -qi "PREEMPT_RT"; then
        log_info "PREEMPT_RT kernel enabled OK"
    else
        log_error "Current kernel does NOT have PREEMPT_RT enabled!"
        log_error "Run apply_rt_patch.sh first, compile and install RT kernel, then reboot"
        log_error "Verify: uname -a | grep PREEMPT_RT"
        exit 1
    fi

    local cpu_count=$(grep -c "^processor" /proc/cpuinfo)
    if [ "$cpu_count" -ge 8 ]; then
        log_info "CPU cores: ${cpu_count} OK"
    else
        log_warn "CPU cores: ${cpu_count} (expected at least 8)"
    fi

    if ! command -v cyclictest > /dev/null 2>&1; then
        log_warn "cyclictest not installed"
        log_info "Installing rt-tests..."
        apt-get update -qq
        apt-get install -y rt-tests stress-ng 2>/dev/null || {
            log_warn "apt install failed, trying to compile..."
            install_rt_tests
        }
    else
        log_info "cyclictest: $(cyclictest --version 2>/dev/null | head -1) OK"
    fi

    if ! command -v stress-ng > /dev/null 2>&1; then
        log_warn "stress-ng not installed (optional, only needed for stress test)"
        apt-get install -y stress-ng 2>/dev/null || true
    else
        log_info "stress-ng installed OK"
    fi
}

#===============================================================================
# Compile and install rt-tests (fallback if apt unavailable)
#===============================================================================
install_rt_tests() {
    local rt_tests_dir="/tmp/rt-tests"
    rm -rf "$rt_tests_dir"
    git clone --depth=1 https://git.kernel.org/pub/scm/utils/rt-tests/rt-tests.git "$rt_tests_dir"
    cd "$rt_tests_dir"
    make
    make install
    log_info "rt-tests compiled and installed OK"
}

#===============================================================================
# 1. Check current realtime configuration
#===============================================================================
check_current_config() {
    echo ""
    echo -e "${CYAN}--- 1. Current Realtime Configuration Check ---${NC}"

    local cmdline=$(cat /proc/cmdline)
    log_info "Kernel boot parameters:"
    echo "    ${cmdline}"

    if echo "$cmdline" | grep -q "isolcpus="; then
        local isol_val=$(echo "$cmdline" | grep -oP 'isolcpus=\S+' | tr -d 'isolcpus=')
        log_info "CPU isolation: isolcpus=${isol_val} OK"
    else
        log_warn "CPU isolation: not configured (isolcpus)"
    fi

    if echo "$cmdline" | grep -q "nohz_full="; then
        local nohz_val=$(echo "$cmdline" | grep -oP 'nohz_full=\S+' | tr -d 'nohz_full=')
        log_info "NO_HZ_FULL: nohz_full=${nohz_val} OK"
    else
        log_warn "NO_HZ_FULL: not configured"
    fi

    if echo "$cmdline" | grep -q "rcu_nocbs="; then
        local rcu_val=$(echo "$cmdline" | grep -oP 'rcu_nocbs=\S+' | tr -d 'rcu_nocbs=')
        log_info "RCU NOCB: rcu_nocbs=${rcu_val} OK"
    else
        log_warn "RCU NOCB: not configured"
    fi

    local gov="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [ -f "$gov" ]; then
        local governor=$(cat "$gov")
        if [ "$governor" = "performance" ]; then
            log_info "CPU frequency governor: ${governor} OK"
        else
            log_warn "CPU frequency governor: ${governor} (recommend: performance)"
        fi
    fi

    echo ""
    log_info "Current CPU status:"
    for cpu in /sys/devices/system/cpu/cpu[0-7]/online; do
        local cpu_idx=$(echo "$cpu" | grep -oP 'cpu\K[0-7]')
        local online=$(cat "$cpu" 2>/dev/null || echo 1)
        if [ "$online" = "1" ]; then
            local gov_val=$(cat "/sys/devices/system/cpu/cpu${cpu_idx}/cpufreq/scaling_governor" 2>/dev/null || echo "N/A")
            echo "    CPU${cpu_idx}: online, governor=${gov_val}"
        else
            echo "    CPU${cpu_idx}: offline"
        fi
    done
}

#===============================================================================
# 2. Apply realtime tuning configuration
#===============================================================================
apply_realtime_config() {
    echo ""
    echo -e "${CYAN}--- 2. Apply Realtime Tuning Configuration ---${NC}"

    log_info "Setting CPU frequency governor to performance..."
    for cpu in /sys/devices/system/cpu/cpu[0-7]; do
        if [ -f "$cpu/cpufreq/scaling_governor" ]; then
            echo performance > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        fi
    done
    log_info "CPU frequency governor set OK"

    log_info "Disabling deep CPU idle states on realtime cores..."
    for cpu in /sys/devices/system/cpu/cpu[4-7]; do
        if [ -d "$cpu/cpuidle" ]; then
            for state in "$cpu/cpuidle/state"*; do
                if [ -f "$state/disable" ]; then
                    echo 1 > "$state/disable" 2>/dev/null || true
                fi
            done
        fi
    done
    log_info "CPU idle states disabled on realtime cores OK"

    log_info "Configuring IRQ affinity (binding to ${IRQ_CPUS})..."

    if systemctl is-active irqbalance > /dev/null 2>&1; then
        log_info "Stopping irqbalance service..."
        systemctl stop irqbalance 2>/dev/null || true
        systemctl disable irqbalance 2>/dev/null || true
    fi

    local IRQ_AFFINITY_MASK=""
    for cpu in $IRQ_CPUS_LIST; do
        IRQ_AFFINITY_MASK="${IRQ_AFFINITY_MASK}1"
    done
    while [ ${#IRQ_AFFINITY_MASK} -lt 8 ]; do
        IRQ_AFFINITY_MASK="0${IRQ_AFFINITY_MASK}"
    done
    IRQ_AFFINITY_MASK=$(printf "%x" $((2#${IRQ_AFFINITY_MASK})))

    local irq_count=0
    for irq_file in /proc/irq/*/smp_affinity; do
        local irq_num=$(echo "$irq_file" | grep -oP '/proc/irq/\K[0-9]+')
        if [ -n "$irq_num" ] && [ "$irq_num" -le 255 ]; then
            local irq_name=$(cat "/proc/irq/${irq_num}/name" 2>/dev/null || echo "")
            if echo "$irq_name" | grep -qiE "rga|npu|gpu|mali|vop|display"; then
                continue
            fi
            echo "$IRQ_AFFINITY_MASK" > "$irq_file" 2>/dev/null || true
            irq_count=$((irq_count + 1))
        fi
    done
    log_info "Bound ${irq_count} IRQs to CPU ${IRQ_CPUS} OK"

    log_info "Setting system realtime scheduling parameters..."
    sysctl -w kernel.sched_rt_runtime_us=-1 2>/dev/null || true
    sysctl -w kernel.sched_rt_period_us=1000000 2>/dev/null || true
    sysctl -w kernel.sched_rt_runtime_us=950000 2>/dev/null || true
    log_info "Realtime scheduling parameters set OK"

    log_info "Setting memory lock limits..."
    cat > /etc/security/limits.d/99-realtime.conf << 'EOF' 2>/dev/null || true
# PREEMPT_RT realtime tuning - added by setup_realtime.sh
@realtime  -  rtprio   99
@realtime  -  memlock  unlimited
*          -  rtprio   99
*          -  memlock  unlimited
EOF
    log_info "Memory lock limits configured OK"

    if ! getent group realtime > /dev/null 2>&1; then
        groupadd realtime 2>/dev/null || true
        log_info "Created realtime user group OK"
    fi

    echo ""
    log_info "Realtime tuning configuration applied OK"
    log_warn "Note: runtime config is volatile (lost after reboot)"
    log_info "For persistence, ensure kernel boot parameters include:"
    echo "    isolcpus=${RT_CPUS} nohz_full=${RT_CPUS} rcu_nocbs=${RT_CPUS} irqaffinity=${IRQ_CPUS}"
}

#===============================================================================
# 3. Run cyclictest latency test
#===============================================================================
run_cyclictest() {
    echo ""
    echo -e "${CYAN}--- 3. cyclictest Latency Test ---${NC}"

    local duration=${CYCLICTEST_DURATION}
    local hist_max=${CYCLICTEST_HISTOGRAM}
    local test_log="/tmp/cyclictest_result_$(date +%Y%m%d_%H%M%S).log"

    log_info "Test configuration:"
    echo "  Duration: ${duration} seconds"
    echo "  Priority: ${CYCLICTEST_PRIORITY}"
    echo "  Interval: ${CYCLICTEST_INTERVAL} us"
    echo ""
    log_info "Running cyclictest latency test..."
    log_info "Please wait ${duration} seconds..."

    local loops=$((duration * 1000000 / CYCLICTEST_INTERVAL))

    log_info "Running cyclictest on realtime cores (CPU ${RT_CPUS})..."
    taskset -c "${RT_CPUS_LIST}" cyclictest \
        --smp \
        -p "${CYCLICTEST_PRIORITY}" \
        -i "${CYCLICTEST_INTERVAL}" \
        -l "${loops}" \
        -h "${hist_max}" \
        -m \
        -n \
        -q \
        2>&1 | tee "$test_log"

    echo ""

    if [ -f "$test_log" ]; then
        echo -e "${CYAN}--- Test Results ---${NC}"
        echo ""

        while IFS= read -r line; do
            if echo "$line" | grep -q "^#.*Min\|^T:"; then
                echo "  $line"
            fi
        done < "$test_log"

        echo ""
        log_info "Detailed results saved to: ${test_log}"

        local max_latency=$(grep -oP 'Max: \K[0-9]+' "$test_log" | sort -rn | head -1)
        if [ -n "$max_latency" ]; then
            echo ""
            echo -e "${CYAN}--- Metric Evaluation ---${NC}"
            echo "  Max latency: ${max_latency} us"
            if [ "$max_latency" -lt 20 ]; then
                echo -e "  ${GREEN}PASS: Idle latency < 20 us OK${NC}"
            elif [ "$max_latency" -lt 50 ]; then
                echo -e "  ${YELLOW}WARN: Idle latency < 50 us${NC}"
            else
                echo -e "  ${RED}FAIL: Idle latency >= 50 us, needs further tuning${NC}"
            fi
        fi
    fi
}

#===============================================================================
# 4. Run stress latency test
#===============================================================================
run_stress_test() {
    echo ""
    echo -e "${CYAN}--- 4. Stress Latency Test (stress-ng + cyclictest) ---${NC}"

    if ! command -v stress-ng > /dev/null 2>&1; then
        log_error "stress-ng not installed, cannot run stress test"
        log_info "Install: apt-get install -y stress-ng"
        exit 1
    fi

    local duration=${CYCLICTEST_DURATION}
    local test_log="/tmp/cyclictest_stress_$(date +%Y%m%d_%H%M%S).log"
    local stress_log="/tmp/stress_${duration}s.log"

    log_info "Stress test configuration:"
    echo "  Duration: ${duration} seconds"
    echo "  stress-ng: CPU load + memory pressure + I/O load"
    echo ""

    log_info "Starting stress-ng on non-realtime cores (CPU 0-3)..."

    killall stress-ng 2>/dev/null || true
    sleep 1

    taskset -c "${IRQ_CPUS_LIST}" stress-ng \
        --cpu 4 \
        --cpu-method matrixprod \
        --io 2 \
        --vm 2 \
        --vm-bytes 512M \
        --hdd 1 \
        --hdd-bytes 1G \
        --timeout "${duration}s" \
        --metrics-brief \
        &> "$stress_log" &

    local stress_pid=$!
    sleep 2

    if kill -0 $stress_pid 2>/dev/null; then
        log_info "stress-ng running in background (PID: ${stress_pid})"
    else
        log_warn "stress-ng failed to start, check log: ${stress_log}"
    fi

    log_info "Running cyclictest on realtime cores (CPU ${RT_CPUS}) under load..."
    local loops=$((duration * 1000000 / CYCLICTEST_INTERVAL))

    taskset -c "${RT_CPUS_LIST}" cyclictest \
        --smp \
        -p "${CYCLICTEST_PRIORITY}" \
        -i "${CYCLICTEST_INTERVAL}" \
        -l "${loops}" \
        -h "${CYCLICTEST_HISTOGRAM}" \
        -m \
        -n \
        -q \
        2>&1 | tee "$test_log"

    wait $stress_pid 2>/dev/null || true

    echo ""

    if [ -f "$test_log" ]; then
        echo -e "${CYAN}--- Stress Test Results ---${NC}"
        echo ""

        while IFS= read -r line; do
            if echo "$line" | grep -q "^#.*Min\|^T:"; then
                echo "  $line"
            fi
        done < "$test_log"

        echo ""

        local max_latency=$(grep -oP 'Max: \K[0-9]+' "$test_log" | sort -rn | head -1)
        if [ -n "$max_latency" ]; then
            echo -e "${CYAN}--- Stress Metric Evaluation ---${NC}"
            echo "  Max loaded latency: ${max_latency} us"
            if [ "$max_latency" -lt 50 ]; then
                echo -e "  ${GREEN}PASS: Loaded latency < 50 us OK${NC}"
            elif [ "$max_latency" -lt 100 ]; then
                echo -e "  ${YELLOW}WARN: Loaded latency < 100 us${NC}"
            else
                echo -e "  ${RED}FAIL: Loaded latency >= 100 us, needs further tuning${NC}"
            fi
        fi

        log_info "Detailed results saved to: ${test_log}"
        log_info "stress-ng log: ${stress_log}"
    fi

    killall stress-ng 2>/dev/null || true
}

#===============================================================================
# 5. Restore default configuration
#===============================================================================
restore_defaults() {
    echo ""
    echo -e "${YELLOW}--- 5. Restore Default Configuration ---${NC}"

    log_info "This will restore default system configuration..."

    log_info "Restoring CPU frequency governor..."
    for cpu in /sys/devices/system/cpu/cpu[0-7]; do
        if [ -f "$cpu/cpufreq/scaling_governor" ]; then
            echo schedutil > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
        fi
    done

    log_info "Restoring CPU idle states..."
    for cpu in /sys/devices/system/cpu/cpu[4-7]; do
        if [ -d "$cpu/cpuidle" ]; then
            for state in "$cpu/cpuidle/state"*; do
                if [ -f "$state/disable" ]; then
                    echo 0 > "$state/disable" 2>/dev/null || true
                fi
            done
        fi
    done

    log_info "Starting irqbalance service..."
    systemctl enable irqbalance 2>/dev/null || true
    systemctl start irqbalance 2>/dev/null || true

    log_info "Restoring scheduler parameters..."
    sysctl -w kernel.sched_rt_runtime_us=950000 2>/dev/null || true

    log_info "Configuration restored OK"
    log_warn "For full restore, remove isolcpus/nohz_full/rcu_nocbs from kernel cmdline and reboot"
}

#===============================================================================
# Main function
#===============================================================================
main() {
    local CHECK_ONLY=false
    local APPLY=false
    local CYCLIC_ONLY=false
    local STRESS_TEST=false
    local RESTORE=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --check-only)   CHECK_ONLY=true; shift ;;
            --apply)        APPLY=true; shift ;;
            --cyclictest)   CYCLIC_ONLY=true; shift ;;
            --stress)       STRESS_TEST=true; shift ;;
            --restore)      RESTORE=true; shift ;;
            --help|-h)      usage; exit 0 ;;
            *)              echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Default (no flags): apply + test
    if [ "$CHECK_ONLY" = false ] && [ "$APPLY" = false ] \
        && [ "$CYCLIC_ONLY" = false ] && [ "$STRESS_TEST" = false ] && [ "$RESTORE" = false ]; then
        APPLY=true
    fi

    print_banner
    check_root
    check_prerequisites

    check_current_config

    if [ "$CHECK_ONLY" = true ]; then
        log_info "Check mode complete OK"
        exit 0
    fi

    if [ "$RESTORE" = true ]; then
        restore_defaults
        exit 0
    fi

    if [ "$APPLY" = true ]; then
        log_info ""
        read -p "  Apply realtime tuning configuration? (Y/n): " confirm
        confirm=${confirm:-Y}
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            apply_realtime_config
        else
            log_info "Skipping configuration apply"
        fi
    fi

    if [ "$CYCLIC_ONLY" = true ] || [ "$APPLY" = true ]; then
        run_cyclictest
    fi

    if [ "$STRESS_TEST" = true ]; then
        run_stress_test
    fi

    echo ""
    echo -e "${CYAN}================================================${NC}"
    echo -e "${CYAN}  Realtime Tuning Complete${NC}"
    echo -e "${CYAN}================================================${NC}"
    echo ""
    echo "  Tips:"
    echo "  1. Runtime config is volatile (lost after reboot)"
    echo "  2. For persistence, kernel boot params should include:"
    echo "     isolcpus=${RT_CPUS} nohz_full=${RT_CPUS}"
    echo "     rcu_nocbs=${RT_CPUS} irqaffinity=${IRQ_CPUS}"
    echo "  3. Add user to realtime group:"
    echo "     sudo usermod -aG realtime \$USER"
    echo "  4. View help: bash $0 --help"
    echo ""
}

main "$@"
