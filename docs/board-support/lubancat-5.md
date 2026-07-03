# 鲁班猫5 (LubanCat-5) 支持说明

> **SoC**: Rockchip RK3588  
> **厂商**: 野火电子 (EmbedFire)  
> **验证状态**: ✅ 主力开发板（实测）

## 硬件规格

| 项目 | 规格 |
|------|------|
| CPU | 4×Cortex-A76 @2.4GHz + 4×Cortex-A55 @1.8GHz |
| NPU | 6 TOPS (三核, 每核 2TOPS) |
| RAM | 8GB / 16GB LPDDR4x |
| 存储 | 32GB / 64GB / 128GB eMMC |
| 网络 | 双 2.5GbE (RTL8125BG) |
| USB | USB 3.0 ×2, USB 2.0 ×2, Type-C (DP+PD) |
| 显示 | HDMI 2.1 (8K@60), MIPI DSI, eDP |
| GPIO | 40-pin 树莓派兼容排针 |

## 已验证功能

| 功能模块 | 状态 | 说明 |
|----------|------|------|
| PREEMPT_RT 内核 | ✅ | 5.10.198-rt97, P99 抖动 <50us |
| AI 视觉流水线 | ✅ | YOLOv5s 25.7 FPS (端到端) |
| NPU 纯推理 | ✅ | 46 FPS (21.7ms/infer) |
| OPC UA Server | ✅ | open62541 v1.3, 20 检测槽位 |
| Modbus TCP | ✅ | libmodbus 3.1.10, 多客户端 |
| EtherCAT | ✅ | IgH Master 1.6, eth1 专用 |
| CAN FD | ✅ | MCP2518FD, SocketCAN |
| 麒麟OS V10 | ✅ | 桌面版/服务器版均通过 |
| NeoCertify | ✅ | 兼容性评分 95+ |

## 操作系统镜像

| 系统 | 下载 | 说明 |
|------|------|------|
| Ubuntu 22.04 (推荐) | [野火官方镜像](https://embedfire.com) | 出厂系统，开箱即用 |
| Armbian | [armbian.com](https://armbian.com) | 社区维护 |
| KylinOS V10 | 联系麒麟获取 | 需额外适配 |

## 部署指南

```bash
# 1. 烧录 Ubuntu 22.04 镜像
# 2. 首次启动后配置网络
# 3. 一键安装工具包
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab
sudo bash middleware/os-compat-layer/one_click_install.sh

# 4. 构建 RT 内核 (可选)
sudo bash middleware/realtime-kernel/PREEMPT_RT_GUIDE.sh

# 5. 验证安装
python3 middleware/os-compat-layer/compat_checker.py
```

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|----------|
| HDMI 热插拔偶发无输出 | 低 | 重启 display manager |
| WiFi/BT 需额外模块 | RTL8822CE | 官方配件或 USB dongle |
| M.2 NVMe 仅 PCIe 2.0 ×1 | 带宽受限 | 使用 eMMC 作为主力存储 |

## 引脚复用 (GPIO)

GPIO 默认功能配置参考 `lubancat-5-pinmux.yaml`（若存在）。主要注意：

- `GPIO1_A4` (PWM12): 可用于 EtherCAT 同步信号
- `UART2`: /dev/ttyS2, 用于 Modbus RTU
- `SPI1`: 接 MCP2518FD CAN 控制器
