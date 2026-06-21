# RK3588 Linux 工业实时性调优指南

> 目标：在 RK3588 Ubuntu 22.04 上实现中断延迟 < 50μs

## 原理概述

RK3588 的 8 核 CPU 分为两个 cluster：
- **Cluster 0**：4× Cortex-A76（大核），CPU 0-3
- **Cluster 1**：4× Cortex-A55（小核），CPU 4-7

推荐将实时任务绑定到 CPU 4-7（A55），将非关键中断和用户空间任务限制在 CPU 0-3（A76）。

## 步骤一：编译 PREEMPT_RT 内核

```bash
cd patches/preempt_rt
bash apply_rt_patch.sh
```

脚本自动完成：
1. 下载对应 BSP 内核源码
2. 打上 PREEMPT_RT 补丁
3. 配置内核选项（启用完全抢占）
4. 编译并安装

## 步骤二：配置内核启动参数

编辑 `/boot/extlinux/extlinux.conf` 或 `/boot/armbianEnv.txt`，添加：

```
isolcpus=4-7 nohz_full=4-7 rcu_nocbs=4-7 irqaffinity=0-3 nosoftlockup
```

参数说明：
- `isolcpus=4-7`：隔离 A55 核心，调度器不会自动向其分配任务
- `nohz_full=4-7`：禁用 tick（定时器中断），减少抖动
- `rcu_nocbs=4-7`：RCU 回调不在此核心执行
- `irqaffinity=0-3`：所有中断默认绑定到 A76 核心
- `nosoftlockup`：禁用软锁检测（避免高优先级任务误判）

## 步骤三：中断亲和力微调

```bash
# 将关键设备中断绑定到特定核心
echo 2 > /proc/irq/<ETH_IRQ>/smp_affinity_list  # 网卡中断→核心2
echo 3 > /proc/irq/<USB_IRQ>/smp_affinity_list  # USB中断→核心3

# GPU/NPU 中断留在 A76 cluster
echo 1 > /proc/irq/<GPU_IRQ>/smp_affinity_list
```

## 步骤四：禁用 CPU 空闲

```bash
# 禁用 A55 核心的空闲状态
for cpu in 4 5 6 7; do
    echo 0 > /sys/devices/system/cpu/cpu$cpu/cpuidle/state*/disable 2>/dev/null || true
done

# 固定 CPU 频率（可选，避免 DVFS 延迟）
echo performance > /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor
```

## 步骤五：验证延迟

```bash
# 安装 rt-tests
sudo apt install rt-tests

# 运行 cyclictest（在隔离的核心上）
sudo taskset -c 4 cyclictest -t1 -p99 -i200 -n -D 300 -h 200 -q > /tmp/cyclictest.log

# 分析结果
grep "Max Latencies" /tmp/cyclictest.log
```

**预期结果**：
- 空闲状态：最大延迟 < 20μs
- 高负载（stress-ng + 网络流量）：最大延迟 < 50μs

## 步骤六：生成调优诊断报告

```bash
# 运行自动化报告生成
bash /opt/rk3588-toolkit/tools/diagnose.sh
```

报告将输出：
- cyclictest 延迟分布（直方图）
- 中断亲和力检查结果
- CPU 隔离状态验证
- DMA-BUF 和 RGA 就绪情况

## 注意事项

1. **不碰 AMP**：本方案仅使用主线 PREEMPT_RT，不使用任何闭源 AMP 组件
2. **客户侧编译**：所有补丁以脚本形式提供，客户在自己的设备上编译内核
3. **法律合规**：不直接分发修改后的内核二进制文件，完全规避 GPL 风险

## 已知限制

- CPU 0-3 的实时性不如 4-7（A76 更复杂，中断延迟略高）
- 禁用 nohz_full 后，4-7 核心的 /proc/stat 统计可能不更新（正常现象）
- GPIO 中断延迟略高于内核定时器，但仍在 50μs 以内
