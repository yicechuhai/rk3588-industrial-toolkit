# Radxa ROCK 5B 支持说明

> **SoC**: Rockchip RK3588（完整版）  
> **厂商**: 瑞莎科技 (Radxa)  
> **验证状态**: ✅ 已验证（ROCK 5B 16GB 实测）

## 硬件规格

| 项目 | 规格 |
|------|------|
| CPU | 4×Cortex-A76 @2.4GHz + 4×Cortex-A55 @1.8GHz |
| NPU | 6 TOPS (三核, 每核 2TOPS) |
| RAM | 4GB / 8GB / 16GB / 32GB LPDDR4x |
| 存储 | eMMC (可选) + microSD + M.2 M-Key |
| 网络 | 2.5GbE (RTL8125BG) ×1 + WiFi 6E (AX210, M.2 E-Key) |
| USB | USB 3.0 ×2, USB 2.0 ×2, Type-C (DP+PD) ×1 |
| 显示 | 双 HDMI (8K@60 + 4K@60), MIPI DSI |
| 扩展 | M.2 M-Key (PCIe 3.0 ×4), M.2 E-Key (WiFi/BT) |
| GPIO | 40-pin 树莓派兼容排针 |

## 亮点特性

- **树莓派 40-pin 兼容**: 可直接使用大部分树莓派 HAT
- **PCIe 3.0 ×4 M.2**: 所有 RK3588 板卡中最快的 NVMe 接口
- **WiFi 6E**: 6GHz 频段工业无线通讯
- **Radxa SPI Flash**: 支持 SPI Flash 启动，无需 SD 卡

## 已验证功能

| 功能模块 | 状态 | 说明 |
|----------|------|------|
| PREEMPT_RT 内核 | ✅ | Radxa 官方提供 RT 内核配置 |
| AI 视觉流水线 | ✅ | YOLOv5s/YOLOv8n 均稳定 |
| NPU 纯推理 | ✅ | 46 FPS |
| OPC UA Server | ✅ | 通过 open62541 验证 |
| Modbus TCP | ✅ | 以太网 + USB-RS485 |
| EtherCAT | ⚠️ | 单网口限制；可通过 USB-Ethernet 扩展 |
| 麒麟OS V10 | ✅ | Radxa 提供基础适配 |
| NeoCertify | ✅ | 兼容性评分 90+ |

## ROCK 5B 与 ROCK 5B+ 差异

| 差异项 | ROCK 5B | ROCK 5B+ |
|--------|---------|----------|
| 网络 | 1×2.5GbE | 双 2.5GbE |
| WiFi | M.2 E-Key 模块 | 板载 WiFi 6 |
| M.2 M-Key | PCIe 3.0 ×4 | PCIe 3.0 ×4 |
| EtherCAT | ⚠️ USB 扩展 | ✅ 双网口原生支持 |

> 📌 如需 EtherCAT 主站，建议选择 **ROCK 5B+**（双网口原生支持）。

## 部署指南

```bash
# 1. 烧录官方 Radxa OS (Debian/Ubuntu) 或 Armbian
# 2. SPI Flash 方式 (推荐，不依赖 SD/eMMC)
#    rsetup → SPI Flash 启动
# 3. 一键安装
git clone https://gitee.com/RK3588kaifa/RK3588-OpenLab.git
cd RK3588-OpenLab
sudo bash middleware/os-compat-layer/one_click_install.sh

# 4. 如需 EtherCAT (ROCK 5B+ 或 USB-Ethernet 扩展)
# USB-Ethernet: 将 eth1 配置为 EtherCAT 实时通道
sudo bash middleware/industrial-protocol/install_ethercat.sh
```

## GPIO 映射 (40-pin 树莓派兼容)

ROCK 5B 的 40-pin GPIO 与树莓派引脚物理兼容，但功能映射不同。使用 Radxa `rsetup` 工具配置引脚复用：

```bash
sudo rsetup          # 图形化配置引脚功能
sudo gpio readall    # 查看当前引脚映射
```

## 已知问题

| 问题 | 影响 | 解决方案 |
|------|------|------|
| 单网口 EtherCAT 受限 | 实时+普通流量竞争 | 升级 ROCK 5B+ 或 USB-Ethernet |
| 早期批次散热不足 | NPU 满载可达 78°C | 官方散热片 + 风扇套件 |
| SPI Flash 启动有学习成本 | 新手可能不会配 | 默认仍用 SD/eMMC |
| WiFi 模块需 M.2 槽插入 | 额外成本 | ROCK 5B+ 板载 WiFi |
