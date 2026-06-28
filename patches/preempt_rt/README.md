# PREEMPT_RT 实时补丁

## 免责声明

本目录仅包含**自动化编译脚本和补丁说明**，不包含任何编译好的内核二进制文件。
用户需在自己的 RK3588 设备上运行脚本完成编译和安装。

## 文件说明

| 文件 | 功能 |
|------|------|
| `apply_rt_patch.sh` | 自动下载内核源码 → 打 PREEMPT_RT 补丁 → 编译 → 安装 → 配置引导 |
| `setup_realtime.sh` | CPU 隔离 + 中断亲和力绑定 + cyclictest 延迟验证 |

## 使用方法

### 第一步：编译安装 PREEMPT_RT 内核

```bash
# 1. 安装编译依赖
sudo apt install -y build-essential libncurses-dev flex bison libssl-dev libelf-dev

# 2. 运行补丁脚本（完整流程）
cd patches/preempt_rt
sudo bash apply_rt_patch.sh

# 3. 重启并选择 RT 内核
sudo reboot
```

### 第二步：配置实时性参数并验证

```bash
# 1. 验证 RT 内核
uname -a | grep PREEMPT_RT

# 2. 一键配置 + 测试（推荐）
sudo bash setup_realtime.sh

# 3. 或者分步操作
sudo bash setup_realtime.sh --apply         # 仅应用配置
sudo bash setup_realtime.sh --cyclictest    # 仅运行延迟测试
sudo bash setup_realtime.sh --stress        # 满载延迟测试
```

## 一键全流程

```bash
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit
sudo bash patches/preempt_rt/apply_rt_patch.sh    # ~45-60分钟
sudo reboot
# 重启后：
sudo bash patches/preempt_rt/setup_realtime.sh     # ~5分钟
```

## 预期效果

| 指标 | 空闲 | 满载 | 验证命令 |
|------|------|------|---------|
| 中断延迟 | < 20 μs | < 50 μs | `cyclictest -p99 -D300 -m -n` |
| CPU 隔离 | 核心 4-7 专用于实时任务 | | `cat /proc/cmdline \| grep isolcpus` |
| 调频策略 | performance | | `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` |

实测数据（NanoPC T6, Debian 11, 内核 6.1.141-rt52）：
- 空闲 cyclictest: Min 3μs / Avg 5μs / Max 21μs
- 满载 cyclictest: Min 4μs / Avg 8μs / Max 46μs

## 技术说明

本补丁基于 Linux 社区主线 PREEMPT_RT 补丁（Linux 6.12 已正式合入），
通过以下策略实现硬实时性能：

1. **CPU 隔离（isolcpus=4-7）**：将 4-7 号核心专用于实时任务
2. **中断亲和力绑定（irqaffinity=0-3）**：将非关键中断绑定到 0-3 号核心
3. **禁用 CPU 空闲/调频**：消除 C-State 切换延迟
4. **nohz_full + rcu_nocbs**：减少内核抖动

### 延迟来源及优化

| 延迟来源 | 典型延迟 | 优化手段 |
|----------|---------|---------|
| C-State 唤醒 | 10-100 μs | idle=halt + CPU 离线空闲深度 |
| 中断干扰 | 5-50 μs | irqaffinity + 线程化中断 |
| TLB 抖动 | 3-20 μs | nohz_full |
| RCU 回调 | 2-10 μs | rcu_nocbs |
| 调频切换 | 5-30 μs | performance governor |

## 兼容性

| 板卡 | 状态 | 备注 |
|------|------|------|
| NanoPC T6 (Debian 11) | ✅ 已验证 | 8GB LPDDR4x |
| 鲁班猫 8 | 🟡 待验证 | 8GB LPDDR5 |
| Radxa Rock 5B | 🟡 理论兼容 | 需确认 BSP 内核版本 |
| Orange Pi 5 | 🟡 理论兼容 | 需确认 BSP 内核版本 |

## 编译时间参考

| 板卡 | 内存 | 编译时间 (8线程) | 磁盘使用 |
|------|------|-----------------|---------|
| NanoPC T6 | 8GB | ~40 分钟 | ~5GB |
| 鲁班猫 8 | 8GB | ~40 分钟 | ~5GB |

## 故障排除

### 内核编译失败

```bash
# 查看编译日志
cat /opt/rk3588-toolkit/rt-kernel/build_6.1.141_rt.log | tail -50

# 常见原因：内存不足 → 减少并行度
make -j2 ARCH=arm64 Image modules dtbs

# 常见原因：磁盘空间不足
df -h /opt/rk3588-toolkit/
```

### 重启后没有 RT 内核选项

```bash
# 检查 extlinux.conf
cat /boot/extlinux/extlinux.conf | grep -A 3 "PREEMPT_RT"

# 手动添加引导条目（参考脚本生成的配置）
```

### cyclictest 延迟过高

```bash
# 检查是否真的在隔离核心上运行
taskset -cp $(pgrep -x cyclictest)

# 检查是否有其他进程干扰
cat /proc/cmdline | grep isolcpus
cat /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor
```

## 许可证

本脚本采用 Apache 2.0。PREEMPT_RT 补丁本身遵循 GPLv2。
