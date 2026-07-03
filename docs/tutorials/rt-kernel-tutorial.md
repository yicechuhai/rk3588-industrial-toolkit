# 实时内核配置教程 (PREEMPT_RT)

> 🎯 为 RK3588 构建 PREEMPT_RT 实时内核，实现 <50us 抖动延迟

## 背景

标准 Linux 内核的延迟抖动在毫秒级 (1-10ms)，无法满足 EtherCAT (1kHz 周期 = 1ms) 和硬实时控制需求。

PREEMPT_RT 补丁将内核变为**完全可抢占**，将最大延迟降低到 **<50us**（RK3588 实测 P99=0.6us）。

## 前置要求

- RK3588 开发板
- Ubuntu 22.04 或 Debian 11+（宿主机或直接在板卡上编译）
- **至少 15GB 磁盘空间**（编译产物大）
- 稳定的电源（编译 30-60 分钟）

## 1. 自动构建 (推荐)

项目内置了一键构建脚本：

```bash
# 直接运行
sudo bash middleware/realtime-kernel/PREEMPT_RT_GUIDE.sh

# 脚本会自动:
# 1. 检测当前内核版本
# 2. 下载匹配的 RT 补丁
# 3. 配置 PREEMPT_RT 选项
# 4. 交叉编译或本地编译
# 5. 安装内核 + 更新启动项
```

### 自定义参数

```bash
# 指定内核版本和 RT 补丁
KERNEL_VER="5.10.198" RT_PATCH="patch-5.10.198-rt97.patch" \
sudo bash middleware/realtime-kernel/PREEMPT_RT_GUIDE.sh

# 使用 version_matrix.yaml 自动匹配
# 文件已内置 7 个 BSP 内核 → RT 补丁的映射
```

## 2. 手动构建

### 2.1 下载源码与补丁

```bash
# Rockchip BSP 内核
git clone -b linux-5.10-gen-rkr4.1 https://github.com/rockchip-linux/kernel.git
cd kernel

# RT 补丁
wget https://cdn.kernel.org/pub/linux/kernel/projects/rt/5.10/patch-5.10.198-rt97.patch.xz
xz -d patch-5.10.198-rt97.patch.xz
patch -p1 < patch-5.10.198-rt97.patch
```

### 2.2 配置内核

```bash
# 使用 Rockchip 默认配置
make ARCH=arm64 rockchip_linux_defconfig

# 开启 PREEMPT_RT (menuconfig)
make ARCH=arm64 menuconfig

# 导航到:
# General setup → Preemption Model → Fully Preemptible Kernel (RT)
# 确认:
#   CONFIG_PREEMPT_RT=y
#   CONFIG_HIGH_RES_TIMERS=y
#   CONFIG_HZ_1000=y
```

### 2.3 编译

```bash
# 本地编译 (在 RK3588 上, 约 40-60 分钟)
make ARCH=arm64 -j$(nproc) Image modules dtbs

# 安装
sudo make ARCH=arm64 modules_install
sudo cp arch/arm64/boot/Image /boot/Image-rt
sudo cp arch/arm64/boot/dts/rockchip/rk3588*.dtb /boot/
```

### 2.4 更新启动项

```bash
# Ubuntu 使用 flash-kernel
sudo flash-kernel

# 或手动更新 extlinux
sudo vim /boot/extlinux/extlinux.conf
# 添加:
# label Ubuntu RT
#   kernel /boot/Image-rt
#   fdt /boot/rk3588-lubancat-5.dtb
```

重启后验证：
```bash
uname -r
# 期望: 5.10.198-rt97

cat /sys/kernel/realtime
# 期望: 1
```

## 3. 实时性能验证

### 3.1 抖动测试

```bash
# 项目内置测试工具
sudo python3 middleware/industrial-protocol/jitter_monitor.py -d 60

# 输出示例:
# ┌──────────────┬───────────┬──────────┐
# │   Percentile │  Latency  │  Status  │
# ├──────────────┼───────────┼──────────┤
# │   P50        │  0.12 us  │   ✅     │
# │   P99        │  0.60 us  │   ✅     │
# │   P99.9      │  1.20 us  │   ✅     │
# │   Max        │  3.80 us  │   ✅     │
# └──────────────┴───────────┴──────────┘
# Target: <50us. Result: PASS ✅
```

### 3.2 cyclictest (行业标准)

```bash
sudo apt install rt-tests
sudo cyclictest -l 1000000 -m -Sp99 -i 200 -h 400 -q > cyclictest.log

# 分析结果
grep "Max" cyclictest.log
```

## 4. CPU 隔离

实时任务与普通任务应在不同的 CPU 核上：

```bash
# 隔离 CPU 4-7 给实时任务
sudo bash middleware/industrial-protocol/cpu_isolation.sh isolate 4-7

# IRQ 亲和性调优
sudo bash middleware/industrial-protocol/irq_affinity.sh

# 验证
cat /proc/cmdline | grep isolcpus
cat /proc/irq/*/smp_affinity
```

### CPU 分配建议

| CPU | 类型 | 用途 |
|-----|------|------|
| 0-1 | A55 (小核) | 系统/网络中断 |
| 2-3 | A55 (小核) | Dashboard Web 服务 |
| 4-5 | A76 (大核) | AI 推理 (SCHED_RR) |
| 6-7 | A76 (大核) | EtherCAT 主站 (SCHED_FIFO, prio=99) |

## 5. 版本兼容矩阵

| BSP 内核 | RT 补丁 | 板卡 | 状态 |
|----------|---------|------|------|
| 5.10.110 | patch-5.10.110-rt69 | NanoPC T6 | ✅ |
| 5.10.160 | patch-5.10.160-rt82 | Orange Pi 5 | ✅ |
| 5.10.198 | patch-5.10.198-rt97 | LubanCat-5 | ✅ 推荐 |
| 6.1.43 | patch-6.1.43-rt14 | ROCK 5B | ✅ |

完整映射见 `middleware/realtime-kernel/version_matrix.yaml`。

## 6. 常见问题

**Q: 编译内核太慢？**
- 在 x86_64 上交叉编译：10-15 分钟
- 使用 Docker: `docker-compose build`

**Q: 启动后 panic？**
- 检查是否加载了闭源驱动（如 Mali GPU）
- 添加 `initcall_debug` 到内核启动参数排查

**Q: 抖动仍然 > 50us？**
- 关闭 CPU 频率调节: `cpufreq-set -g performance`
- 关闭 USB 自动挂起: `echo -1 > /sys/module/usbcore/parameters/autosuspend`
- 禁用透明大页: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`
