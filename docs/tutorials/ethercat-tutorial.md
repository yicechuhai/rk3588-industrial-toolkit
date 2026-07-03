# EtherCAT 主站配置教程 (IgH Master)

> 🎯 在 RK3588 上配置 EtherCAT 主站，实现 1ms 周期实时控制

## 背景

EtherCAT (Ethernet for Control Automation Technology) 是工业自动化领域最快的现场总线之一。使用 IgH EtherCAT Master（开源主站协议栈），RK3588 可同时运行 AI 推理 + 实时 EtherCAT 控制。

## 硬件要求

| 项目 | 要求 |
|------|------|
| 网口 | **双网口** (eth0 普通 + eth1 EtherCAT 专用) |
| 支持板卡 | LubanCat-5, NanoPC T6, ROCK 5B+ |
| 实时内核 | PREEMPT_RT (必须) |
| 从站 | 支持标准 EtherCAT 协议的伺服/IO/CAN 模块 |

> ⚠️ 单网口板卡 (Orange Pi 5, ROCK 5B) 不推荐：实时与普通流量竞争同一物理通道。

## 1. 安装

### 一键安装

```bash
sudo bash middleware/industrial-protocol/install_ethercat.sh
```

脚本自动完成：
1. 安装 `libethercat` 依赖
2. 编译 IgH Master
3. 配置 `/etc/ethercat.conf`
4. 设置 systemd 服务
5. 配置 udev 规则

### 手动安装

```bash
# 依赖
sudo apt install build-essential linux-headers-$(uname -r) autoconf libtool

# 克隆 IgH Master
git clone https://gitlab.com/etherlab.org/ethercat.git
cd ethercat
./bootstrap
./configure --enable-generic --enable-rtmutex --with-linux-dir=/usr/src/linux-headers-$(uname -r)
make -j$(nproc)
sudo make install
sudo make modules_install
sudo depmod
```

## 2. 配置

### /etc/ethercat.conf

```bash
# 主站使用的网卡 — 必须是专用网口
MASTER0_DEVICE="eth1"

# 主站驱动程序
DEVICE_MODULES="generic"

# 周期时间 (微秒)
# 1ms = 1000us (推荐)
CYCLETIME=1000
```

### 网卡 MAC 地址

```bash
# 确认 eth1 为实时网口
sudo bash middleware/industrial-protocol/ethercat_mac_setup.sh eth1
```

### systemd 服务

```bash
# 启动
sudo systemctl start ethercat
sudo systemctl enable ethercat

# 验证
sudo systemctl status ethercat
dmesg | grep -i ethercat
```

## 3. 验证主站

```bash
# 查看主站状态
ethercat master

# 输出示例:
# Master0
#   Phase: Operation
#   Active: yes
#   Slaves: 3
#   Ethernet devices:
#     Main: eth1 (00:11:22:33:44:55)
#     Backup: none

# 扫描从站
ethercat slaves

# 输出示例:
# 0  0:0  PREOP  +  EK1100 EtherCAT Coupler
# 1  0:1  PREOP  +  EL1008 8Ch. Dig. Input
# 2  0:2  PREOP  +  EL2008 8Ch. Dig. Output
```

## 4. Python 控制示例

```python
# ethercat_simple_control.py
import pysoem  # pip install pysoem
import time

# 初始化主站
master = pysoem.Master()
master.open("eth1")  # 专用网口

# 配置
if master.config_init() > 0:
    print(f"Found {len(master.slaves)} slaves")

    # 映射 PDO
    master.config_map()

    # 切换到运行状态
    master.state_check(pysoem.SAFEOP_STATE, 50000)
    slave = master.slaves[0]
    slave.state_check(pysoem.OP_STATE, 50000)

    # 1ms 周期控制循环
    try:
        while True:
            master.send_processdata()
            # 读取输入 (EL1008)
            inputs = slave.input
            # 控制输出 (EL2008)
            slave.output = bytearray([0xFF])  # 全部拉高
            master.receive_processdata()
            time.sleep(0.001)  # 1ms
    except KeyboardInterrupt:
        slave.state = pysoem.INIT_STATE

master.close()
```

## 5. CPU 隔离 + 实时优化

```bash
# 1. 隔离 CPU 6-7 给 EtherCAT
sudo bash middleware/industrial-protocol/cpu_isolation.sh isolate 6-7

# 2. 绑定 EtherCAT 中断到隔离的 CPU
ETH_IRQ=$(cat /proc/interrupts | grep eth1 | awk '{print $1}' | tr -d ':')
echo 2 | sudo tee /proc/irq/$ETH_IRQ/smp_affinity  # CPU1 (eth0)
# eth1 中断通过 isolcpus 自动避开 6-7

# 3. taskset 绑定 EtherCAT 进程
sudo taskset -cp 6,7 $(pgrep ethercat)

# 4. 验证
cat /proc/$(pgrep ethercat)/status | grep Cpus_allowed_list
```

## 6. 完整 AI + EtherCAT 架构

```
┌────────────────────────────────────────────────────┐
│                    RK3588                          │
│                                                    │
│  CPU 0-3 (A55)                CPU 4-7 (A76)        │
│  ┌─────────────┐              ┌──────────────────┐ │
│  │ Dashboard    │              │ CPU 4-5: AI推理  │ │
│  │ Modbus/OPCUA │              │ (SCHED_RR prio50)│ │
│  │ 系统服务     │              │                  │ │
│  └─────────────┘              │ CPU 6-7: EtherCAT│ │
│                               │ (SCHED_FIFO prio99│ │
│   eth0 ────────               │  周期 1ms)       │ │
│   管理网络                    └──────────────────┘ │
│                                         │          │
│                               eth1 ─────┘          │
│                               EtherCAT 专用        │
└────────────────────────────────────────────────────┘
        │                              │
        ▼                              ▼
   [交换机/路由器]            [EtherCAT 从站]
        │                      ├─ 伺服驱动器
   [SCADA/PLC]                 ├─ IO 模块
                               └─ 传感器
```

## 7. 故障排查

| 症状 | 原因 | 解决 |
|------|------|------|
| `ethercat master` 显示 "No socket" | 驱动未加载 | `sudo modprobe ec_master` |
| 从站始终 PREOP | 网线/网卡问题 | `dmesg \| grep ec_` |
| 周期抖动大 (>50us) | RT 内核未正确配置 | 运行 `cyclictest` 验证 |
| `pysoem` 初始化失败 | 权限问题 | `sudo usermod -aG ethercat $USER` |
| eth1 不出现 | 硬件/驱动 | `ip link show`, 检查 dmesg |
