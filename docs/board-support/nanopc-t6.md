# NanoPC T6 支持说明

> **SoC**: Rockchip RK3588（完整版）  
> **厂商**: 友善电子 (FriendlyELEC)  
> **验证状态**: ✅ 主力开发板（实测）

## 硬件规格

| 项目 | 规格 |
|------|------|
| CPU | 4×Cortex-A76 @2.4GHz + 4×Cortex-A55 @1.8GHz |
| NPU | 6 TOPS (三核, 每核 2TOPS) |
| RAM | 4GB / 8GB / 16GB LPDDR4x |
| 存储 | 32GB / 64GB eMMC + microSD + M.2 M-Key |
| 网络 | 双 2.5GbE (RTL8125BG) + WiFi 6 (AX210) |
| USB | USB 3.0 ×1, USB 2.0 ×2, Type-C (DP 1.4 + PD) |
| 显示 | HDMI 2.1 (8K@60), HDMI 2.0 |
| 扩展 | M.2 M-Key (PCIe 3.0 ×1), M.2 E-Key (WiFi) |
| GPIO | 30-pin (非标准) |

## 已验证功能

| 功能模块 | 状态 | 说明 |
|----------|------|------|
| PREEMPT_RT 内核 | ✅ | 5.10.110-rt69, P99 抖动 <40us |
| AI 视觉流水线 | ✅ | YOLOv5s 25.7 FPS, YOLOv8n 更强 |
| NPU 纯推理 | ✅ | 46 FPS |
| OPC UA Server | ✅ | 性能稳定 |
| Modbus TCP | ✅ | 多客户端并发 |
| EtherCAT | ✅ | eth1 专用实时通道 |
| WiFi 6 | ✅ | Intel AX210, 免驱 |
| 麒麟OS V10 | ✅ | 兼容性评分 95+ |
| NeoCertify | ✅ | 通过标准化认证 |

## 操作系统镜像

| 系统 | 下载 | 说明 |
|------|------|------|
| FriendlyELEC (推荐) | [官方下载](https://wiki.friendlyelec.com) | 含 NPU/RGA 驱动，开箱即用 |
| Armbian | [armbian.com](https://armbian.com) | 社区维护 |
| DietPi | [dietpi.com](https://dietpi.com) | 轻量化 |

## 部署指南

```bash
# 1. 从官方下载 FriendlyELEC 镜像，dd 或 Etcher 烧录到 SD/eMMC
# 2. 首次启动后 sudo npi-config 配置网络
# 3. 一键安装 RK3588-OpenLab
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab
sudo bash middleware/os-compat-layer/one_click_install.sh

# 4. EtherCAT 主站配置 (需双网口)
sudo bash middleware/industrial-protocol/install_ethercat.sh
# 编辑 /etc/ethercat.conf: MASTER0_DEVICE=eth1

# 5. 实时性能优化
sudo bash middleware/industrial-protocol/cpu_isolation.sh isolate 4-7
sudo bash middleware/industrial-protocol/irq_affinity.sh
```

## 引脚映射

NanoPC T6 30-pin GPIO:

| Pin | 功能 | 用途建议 |
|-----|------|----------|
| 11 | I2C3_SDA | 传感器 |
| 12 | I2C3_SCL | 传感器 |
| 15 | UART2_TX | Modbus RTU |
| 16 | UART2_RX | Modbus RTU |
| 23 | GPIO3_A0 | EtherCAT SYNC OUT |
| 27 | GPIO3_B5 | 外部触发输入 |

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|------|
| M.2 仅 PCIe 3.0 ×1 | NVMe SSD 带宽受限 | 非瓶颈，推理数据在内存 |
| 散热片被动散热不够 | 满负载 >70°C | 加装 5V PWM 风扇 |
| HDMI 音频偶发断流 | 低 | 用耳机孔或 USB DAC |
