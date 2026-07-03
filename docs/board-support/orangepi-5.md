# Orange Pi 5 支持说明

> **SoC**: Rockchip RK3588S（精简版 RK3588）  
> **厂商**: 深圳迅龙软件 (Orange Pi)  
> **验证状态**: ✅ 已验证（Orange Pi 5 Max 实测）

## 硬件规格

| 项目 | 规格 |
|------|------|
| CPU | 4×Cortex-A76 @2.4GHz + 4×Cortex-A55 @1.8GHz |
| NPU | 6 TOPS (内置, 同 RK3588) |
| RAM | 4GB / 8GB / 16GB / 32GB LPDDR4/4x |
| 存储 | microSD + M.2 M-Key (PCIe 2.0 ×1) |
| 网络 | 2.5GbE (RTL8125BG) ×1 |
| USB | USB 3.0 ×1, USB 2.0 ×2, Type-C ×1 |
| 显示 | HDMI 2.1 (8K@60), MIPI DSI, eDP |
| GPIO | 26-pin (非标, 非树莓派兼容) |

## RK3588 vs RK3588S 差异

| 差异项 | RK3588 | RK3588S |
|--------|--------|---------|
| 封装尺寸 | 23×23mm | 17×17mm |
| 以太网 | 双 2.5GbE | 单 2.5GbE |
| PCIe | PCIe 3.0 ×4 | PCIe 2.0 ×1 |
| SATA | 3×SATA 3.0 | 无 |
| USB 3.0 | 2 个 | 1 个 |
| NPU | 6 TOPS | 6 TOPS (不变) |

> ⚠️ **结论**: AI 推理性能不受影响，NPU 完全一致。工业协议受影响（缺双网卡和 SATA），不适合 EtherCAT + AI 双网口场景。

## 已验证功能

| 功能模块 | 状态 | 说明 |
|----------|------|------|
| PREEMPT_RT 内核 | ✅ | 以 Orange Pi 5 Max 8GB 验证 |
| AI 视觉流水线 | ✅ | YOLOv5s 25+ FPS (端到端) |
| NPU 纯推理 | ✅ | 46 FPS (与 RK3588 一致) |
| OPC UA Server | ✅ | 单网口模式 |
| Modbus TCP | ✅ | 以太网 + RS485 (USB dongle) |
| EtherCAT | ⚠️ | 受限：单网口无法隔离实时/普通流量 |
| 麒麟OS V10 | ✅ | 需手动适配，可能缺失 WiFi 驱动 |

## 推荐使用场景

| 场景 | 适合度 | 说明 |
|------|--------|------|
| AI 视觉边缘盒子 | ⭐⭐⭐⭐⭐ | NPU 满载，单网口够用 |
| Modbus/OPC UA 网关 | ⭐⭐⭐⭐ | 无 EtherCAT 需求时可用 |
| EtherCAT 主站 | ⭐⭐ | 单网口限制，非推荐 |
| 国产化替代方案 | ⭐⭐⭐⭐ | 性价比最优选 |

## 部署指南

```bash
# Orange Pi 官方提供 Ubuntu 22.04 / Debian / Armbian 镜像
# 烧录后首次启动 sudo orangepi-config 配置用户
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab
sudo bash middleware/os-compat-layer/one_click_install.sh

# 如需 RS485
# 使用 USB-RS485 转换器: /dev/ttyUSB0
```

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|------|
| 26-pin GPIO 非标准 | 不兼容树莓派 HAT | 杜邦线手动接线 |
| 散热需额外风扇 | 满负载可达 80°C+ | 官方散热套件或 5V PWM 风扇 |
| WiFi/BT 芯片不稳定 | 偶发断连 | 优先使用有线网络 |
| RK3588S 无 SATA | 无法板载大容量存储 | 使用 M.2 NVMe 或 USB 硬盘盒 |
