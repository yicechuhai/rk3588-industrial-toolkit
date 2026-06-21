# RK3588 工业视觉与实时控制中间件 — 开发文档

> 版本：v1.0.0 | 更新时间：2026-06-21

## 目录

1. [系统架构](#系统架构)
2. [硬件要求](#硬件要求)
3. [快速集成指南](#快速集成指南)
4. [API 参考](#api-参考)
5. [配置文件说明](#配置文件说明)
6. [性能调优指南](#性能调优指南)
7. [故障排查](#故障排查)
8. [扩展开发](#扩展开发)

---

## 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                    用户应用层                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐   │
│  │ Python SDK│  │ C++ SDK  │  │ Modbus/OPC UA Client │   │
│  └─────┬─────┘  └─────┬────┘  └──────────┬───────────┘   │
├────────┼───────────────┼─────────────────┼───────────────┤
│        ▼               ▼                  ▼               │
│  ┌──────────────────────────────────────────────────┐    │
│  │           零拷贝推理引擎 (Zero-Copy Engine)        │    │
│  │   RGA 预处理 → NPU 推理 → RGA 后处理 → OSD 叠加   │    │
│  └──────────────────────┬───────────────────────────┘    │
│                         │                                 │
│  ┌──────────────────────┼───────────────────────────┐    │
│  │    ┌─────────────────▼──────────────────────┐    │    │
│  │    │       工业协议适配层                     │    │    │
│  │    │  Modbus TCP/RTU + OPC UA Server         │    │    │
│  │    └─────────────────┬──────────────────────┘    │    │
│  │                      │                            │    │
│  │    ┌─────────────────▼──────────────────────┐    │    │
│  │    │        实时增强层 (PREEMPT_RT)           │    │    │
│  │    │  CPU隔离 + 中断亲和力 + NOHZ + RCU      │    │    │
│  │    └────────────────────────────────────────┘    │    │
│  └──────────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────────┤
│                  RK3588 硬件平台                           │
│        NPU (6 TOPS) | RGA | VPU | ISP | GPIO             │
└─────────────────────────────────────────────────────────┘
```

## 硬件要求

| 项目 | 最低要求 | 推荐配置 |
|------|---------|---------|
| 芯片 | RK3588 | RK3588 |
| 内存 | 4GB | 8GB+ |
| 存储 | 16GB | 32GB+ (eMMC/SD) |
| 系统 | Ubuntu 22.04 | Ubuntu 22.04 |
| 内核 | 5.10 BSP | 6.1+ PREEMPT_RT |
| 摄像头 | USB 摄像头 | MIPI CSI IMX415/IMX219 |

**已验证兼容板卡**：

- NanoPC T6 (友善之臂)
- 鲁班猫 8 (微雪电子)
- Radxa Rock 5B
- Orange Pi 5 / 5 Max
- 飞凌 OK3588-C / FET3588-C
- 触觉智能 IDO-SOM3588
- 东胜 DSOM-3588

---

## 快速集成指南

### 第一步：环境部署 (5分钟)

```bash
# 克隆仓库
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit

# 安装到系统
sudo bash install.sh

# 运行环境检测
sudo bash /opt/rk3588-toolkit/env_check/check_env.sh
```

### 第二步：确认 NPU 可用

```bash
# 检查 NPU 设备节点
ls -la /dev/dri/renderD128

# 检查 RKNN Runtime
ldconfig -p | grep librknnrt
```

如果未安装，运行 Demo 脚本会自动尝试安装：
```bash
sudo bash /opt/rk3588-toolkit/demo/run_yolov5_demo.sh
```

### 第三步：集成到你的应用

**Python 方式**（推荐用于原型开发）：

```python
import sys
sys.path.insert(0, '/opt/rk3588-toolkit')

from rknn.api import RKNN
import cv2
import numpy as np

# 初始化
rknn = RKNN()
rknn.load_rknn('/opt/rk3588-toolkit/models/yolov5s-640-640.rknn')
rknn.init_runtime(target='rk3588')

# 推理
img = cv2.imread('test.jpg')
# ... 预处理 ...
outputs = rknn.inference(inputs=[preprocessed])
# ... 后处理 ...

rknn.release()
```

**C++ 方式**（推荐用于生产部署）：

参考 `deploy/engine/` 目录下的 C++ SDK 示例。

### 第四步：连接 PLC

编辑 Modbus 映射配置：

```bash
sudo nano /opt/rk3588-toolkit/configs/yaml_templates/modbus_mapping.yaml
```

启动 Modbus TCP 服务：

```bash
python3 /opt/rk3588-toolkit/protocol/modbus_server.py \
    --config /opt/rk3588-toolkit/configs/yaml_templates/modbus_mapping.yaml
```

PLC 端直接读取保持寄存器 40001+ 即可获取检测结果。

---

## API 参考

### Python SDK

#### `class RK3588InferenceEngine`

```python
engine = RK3588InferenceEngine(
    model_path="/opt/rk3588-toolkit/models/yolov5s-640-640.rknn",
    input_size=(640, 640),
    conf_threshold=0.3,
    nms_threshold=0.45,
    npu_core_mask=0x07  # 使用全部3个NPU核心
)
```

**方法**：

| 方法 | 参数 | 返回值 | 说明 |
|------|------|--------|------|
| `infer(image)` | `numpy.ndarray` (H,W,3) | `List[Detection]` | 单帧推理 |
| `infer_batch(images)` | `List[numpy.ndarray]` | `List[List[Detection]]` | 批量推理 |
| `get_stats()` | — | `dict` | 获取性能统计 |
| `release()` | — | — | 释放资源 |

#### `class Detection`

| 属性 | 类型 | 说明 |
|------|------|------|
| `class_id` | `int` | 类别 ID |
| `class_name` | `str` | 类别名称 |
| `confidence` | `float` | 置信度 (0-1) |
| `bbox` | `tuple(x1,y1,x2,y2)` | 边界框坐标 |
| `center` | `tuple(cx,cy)` | 中心点坐标 |
| `area` | `int` | 面积（平方像素） |

### Modbus 映射 API

通过 YAML 配置映射 AI 检测结果到 Modbus 保持寄存器。详见 `configs/yaml_templates/modbus_mapping.yaml`。

### OPC UA API

通过 YAML 配置 OPC UA 服务端节点树。详见 `configs/yaml_templates/opcua_server.yaml`。

---

## 配置文件说明

### 全局配置 `configs/yaml_templates/global_config.yaml`

统一管理所有模块的运行参数，包括：

- **实时性**：CPU 隔离核心、内核命令行参数
- **NPU**：驱动版本、核心掩码、频率策略
- **推理**：输入尺寸、精度、前处理参数
- **摄像头**：USB/MIPI/RTSP 各模式参数
- **OSD**：字体、颜色、线宽配置
- **输出**：日志级别、文件路径、统计间隔

---

## 性能调优指南

### NPU 推理加速

1. **使用 INT8 精度**（默认）：比 FP16 快约 2 倍
2. **启用多 NPU 核心**：`npu_core_mask=0x07`（3核心并行）
3. **固定 NPU 频率**：`echo 1000000000 > /sys/class/devfreq/fde40000.npu/userspace/set_freq`
4. **批处理**：当延迟可接受时，batch_size=4 可提升吞吐量

### 视频流水线优化

- 启用 RGA 硬件缩放（比 OpenCV resize 快 3-5 倍）
- 使用 DMA-BUF 共享内存，避免 CPU 拷贝
- 摄像头输出格式优先选择 NV12（零拷贝到 NPU）

### 实时性调优

详见 `deploy/realtime/` 目录下的补丁脚本和调优指南。

---

## 故障排查

运行诊断工具：

```bash
rk3588-diagnose
```

或手动排查：

| 症状 | 检查项 | 命令 |
|------|--------|------|
| NPU 不可用 | 设备节点 | `ls -la /dev/dri/renderD128` |
| RKNN 加载失败 | Runtime 版本 | `ldconfig -p \| grep rknn` |
| 模型推理慢 | NPU 频率 | `cat /sys/class/devfreq/fde40000.npu/cur_freq` |
| 摄像头无图像 | 设备权限 | `v4l2-ctl --list-devices` |
| 内存不足 | CMA 大小 | `cat /proc/meminfo \| grep Cma` |

---

## 扩展开发

### 添加新模型支持

1. 使用 rknn-toolkit2 将模型转换为 RKNN 格式
2. 将 `.rknn` 文件放入 `/opt/rk3588-toolkit/models/`
3. 在 `configs/yaml_templates/global_config.yaml` 中注册模型配置
4. 创建 Python/C++ 适配器继承 `BaseInferenceEngine`

### 添加新工业协议

1. 在 `deploy/protocol/` 下创建协议适配器
2. 实现 `read_outputs()` 和 `write_inputs()` 接口
3. 添加 YAML 配置模板到 `configs/yaml_templates/`

---

> 更多技术细节请查看 GitHub Issues 或提交新问题。
