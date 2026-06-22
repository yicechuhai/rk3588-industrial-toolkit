# 测试平台硬件档案

## NanoPC T6

| 属性 | 值 |
|------|-----|
| **制造商** | FriendlyElec（友善之臂） |
| **SoC** | RK3588 |
| **内存** | 8GB LPDDR4x |
| **存储** | 64GB eMMC |
| **网络** | 2× 2.5GbE (RTL8125BG) |
| **WiFi/BT** | 可选（M.2 接口） |
| **显示** | HDMI 2.1 + DP 1.4 + MIPI DSI |
| **USB** | USB 3.0 ×2, USB 2.0 ×2 |
| **GPIO** | 40-pin 树莓派兼容 |
| **设备树** | `rk3588-nanopc-t6.dtb` |
| **内核** | 6.1.141 (Armbian, 非BSP内核) |
| **NPU 驱动** | `内核模块已加载 (dmesg确认), debugfs未挂载无法读版本号` |
| **特点** | 社区资料丰富，Armbian 支持好 |

## 鲁班猫 8

| 属性 | 值 |
|------|-----|
| **制造商** | Waveshare（微雪电子） |
| **SoC** | RK3588 |
| **内存** | 8GB LPDDR5 |
| **存储** | 128GB eMMC |
| **网络** | 1× 千兆网口 (RTL8211F) |
| **WiFi/BT** | 板载 AP6256 (WiFi 5 + BT 5.0) |
| **显示** | HDMI 2.1 ×2 + MIPI DSI |
| **USB** | USB 3.0 ×2, USB 2.0 ×2, Type-C |
| **GPIO** | 40-pin 扩展 |
| **设备树** | `rk3588-lubancat-8.dtb` |
| **内核** | 6.1.141 (Armbian, 非BSP内核) |
| **NPU 驱动** | `内核模块已加载 (dmesg确认), debugfs未挂载无法读版本号` |
| **特点** | 出厂带散热风扇，文档中文完善 |

## 关键差异（影响脚本适配）

| 差异点 | NanoPC T6 | 鲁班猫 8 | 影响 |
|--------|-----------|----------|------|
| **内存类型** | LPDDR4x | LPDDR5 | PREEMPT_RT 延迟表现可能不同 |
| **eMMC 容量** | 64GB | 128GB | 内核编译需要 ~15GB |
| **网卡芯片** | RTL8125BG | RTL8211F | 中断亲和力配置不同 |
| **WiFi 模块** | 可选 | 板载 AP6256 | RT 补丁可能影响 WiFi 驱动 |
| **散热** | 需自配 | 出厂带风扇 | 满载测试温度差异 |
| **设备树** | nanopc-t6 | lubancat-8 | 所有硬件路径可能不同 |

## 你的测试记录模板

### 板卡信息（初始化时填写一次）

```yaml
板卡: NanoPC T6  # 或 鲁班猫 8
镜像: Ubuntu 22.04 <具体版本>
内核: 5.10.160  # uname -r
NPU驱动: 0.9.8  # cat /sys/class/misc/rknpu/version
RKNN Runtime: 2.3.2
摄像头: Logitech C920  # USB摄像头型号
```


## 测试记录

### 2026-06-22 · NanoPC T6 基线

- 系统: Debian 11 (非Ubuntu 22.04，需适配)
- 内核: 6.1.141 (标准PREEMPT，非RT)
- NPU: /dev/dri/renderD128 ✅, rknpu 已加载 ✅, 版本无法读取 ⚠️
- RKNN Runtime: 2.3.2 ✅
- RGA: /dev/rga ✅, librga 2.2.0 ✅
- 网络: 无外网 ⚠️
- 汇总: 17 PASS, 6 WARN, 0 FAIL
