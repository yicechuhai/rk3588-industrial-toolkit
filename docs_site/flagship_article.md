# 不用 AMP，在 RK3588 上把 Linux 中断延迟干到 50μs 的真实记录（附全自动脚本）

> 作者：yicechuhai | GitHub: [rk3588-industrial-toolkit](https://github.com/yicechuhai/rk3588-industrial-toolkit)

---

## 先看结果

在 RK3588 开发板（NanoPC T6，Ubuntu 22.04）上，运行 300 秒 cyclictest 压测：

```
# Max Latencies: 38 us  (cyclictest -p99 -t1 -i200 -D300)
# 平均延迟: 8 us
# 99分位延迟: 19 us
```

**没用 Xenomai，没用 RTAI，没用任何闭源 AMP 组件。** 纯 Linux PREEMPT_RT + 内核参数调优。

---

## 为什么要写这篇文章

过去半年，我在 GitHub 和嵌入式社区看到至少 50+ 条类似的问题：

- "RK3588 能做实时控制吗？"
- "NPU 推理 + PLC 通信延迟能到多少？"
- "要不要上 Xenomai？配了三天没跑起来"

作为在 RK3399/RK3588 上踩过无数坑的人，我决定把调优经验整理成一套自动化的脚本和这篇记录。**文末有全套脚本的免费下载链接。**

---

## 核心思路：不跟调度器打架

很多工程师一上来就想"打 RT 补丁→调优先级→完事"。但 PREEMPT_RT 只是把内核变成可抢占的，不等于你的任务就不被干扰了。

真正的硬实时，要做四件事：

### 1. CPU 隔离 (isolcpus)

```
isolcpus=4-7
```

把 A55 小核从调度器完全摘出来。这 4 个核心不会再被任何一个普通进程使用，也不会收到定时器中断（配合 nohz_full）。

**为什么是 A55 而不是 A76？** 因为 A55 的流水线更浅，中断延迟更可预测。A76 的乱序执行和更深的缓存体系反而增加了最差情况的延迟。

### 2. 中断亲和力绑定

```
irqaffinity=0-3
echo 2 > /proc/irq/<ETH_IRQ>/smp_affinity_list
```

把所有中断（网卡、USB、GPU、NPU）绑定到 A76 核心。A55 核心上的实时任务几乎不会收到任何硬件中断。

### 3. 禁用 CPU 空闲

```bash
for cpu in 4 5 6 7; do
    echo 0 > /sys/devices/system/cpu/cpu$cpu/cpuidle/state*/disable
done
```

CPU 进入 C-states 再唤醒的延迟是微秒到毫秒级的。工业场景不需要省电。

### 4. RCU offload

```
rcu_nocbs=4-7
```

RCU（Read-Copy-Update）是内核的核心同步机制，它会在每个 CPU 上定时执行回调。把它们全部卸载到 A76 核心。

---

## 实测数据

在两种场景下测试：

| 场景 | 最大延迟 | 平均延迟 |
|------|---------|---------|
| 空闲（仅 cyclictest） | 21 μs | 6 μs |
| 高负载（stress-ng --cpu 8 + iperf3 千兆网络 + NPU 推理） | 38 μs | 8 μs |

对比未调优的通用内核（同硬件）：

| 场景 | 最大延迟 | 平均延迟 |
|------|---------|---------|
| 空闲 | 156 μs | 12 μs |
| 高负载 | 847 μs | 23 μs |

**优化后最差延迟降低了 22 倍。**

---

## 自动化：一脚本搞定全部

手动调参太痛苦了。我把整个过程封装成了三个脚本：

1. **环境检测** → `check_env.sh`：一键输出 50+ 项硬件/软件/驱动状态，生成 HTML 报告
2. **RT 补丁编译** → `apply_rt_patch.sh`：自动下载内核源码、打补丁、编译
3. **调优配置** → `setup_realtime.sh`：自动配置 isolcpus、中断亲和力、禁用空闲

```bash
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit

# 先看看你板子的状态
sudo bash deploy_scripts/env_check/check_env.sh

# 一键编译 RT 内核并配置
sudo bash patches/preempt_rt/apply_rt_patch.sh
```

---

## 和 Xenomai / AMP 方案的对比

| 方案 | 延迟 | 复杂度 | 法律风险 | 维护成本 |
|------|------|--------|---------|---------|
| **PREEMPT_RT（本文）** | 20-50μs | ⭐ 低 | ✅ 主线内核 | ✅ 社区维护 |
| Xenomai cobalt | 5-15μs | ⭐⭐⭐ 高 | ✅ | ⚠ 需打补丁 |
| OpenAMP | 1-5μs | ⭐⭐⭐⭐⭐ | ⚠ 闭源风险 | ❌ 原厂依赖 |
| 裸机 MCU 协处理 | <1μs | ⭐⭐⭐⭐ | ✅ | ⚠ 需维护两套 |

**除非你需要亚微秒级硬实时（如电机电流环），否则 PREEMPT_RT 完全够用。**

---

## 获取脚本

全开源，Apache 2.0 协议：

👉 [GitHub: yicechuhai/rk3588-industrial-toolkit](https://github.com/yicechuhai/rk3588-industrial-toolkit)

包含：
- 环境检测 + NPU 驱动管理
- YOLOv5s 模型一键部署 Demo
- Modbus TCP 映射模板
- 完整中文文档

---

## 下一篇预告

《RK3588 工业视觉实战：零拷贝推理 + Modbus 输出，5 分钟跑通硬件在环》

---

*本文所有测试在 NanoPC T6 8GB 上进行，系统 Ubuntu 22.04，内核 5.10.160。脚本在鲁班猫 8、Orange Pi 5 Max 上验证通过。*
