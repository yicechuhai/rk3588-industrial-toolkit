# RK3588 Industrial Vision & Real-time Control Middleware — Developer Guide

> Version: v1.0.0 | Updated: 2026-06-21

## Quick Start

```bash
git clone https://github.com/yicechuhai/rk3588-industrial-toolkit.git
cd rk3588-industrial-toolkit
sudo bash install.sh
sudo bash /opt/rk3588-toolkit/env_check/check_env.sh
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Application Layer                   │
│  Python SDK │ C++ SDK │ Modbus/OPC UA Client     │
├─────────────────────────────────────────────────┤
│           Zero-Copy Inference Engine             │
│  RGA Preprocess → NPU Infer → RGA Post → OSD     │
├─────────────────────────────────────────────────┤
│         Industrial Protocol Adapter              │
│    Modbus TCP/RTU + OPC UA Server                │
├─────────────────────────────────────────────────┤
│        Real-time Enhancement (PREEMPT_RT)        │
│   CPU Isolation + IRQ Affinity + NOHZ + RCU      │
├─────────────────────────────────────────────────┤
│              RK3588 Hardware                      │
│   NPU (6 TOPS) | RGA | VPU | ISP | GPIO          │
└─────────────────────────────────────────────────┘
```

## System Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| SoC | RK3588 | RK3588 |
| RAM | 4 GB | 8+ GB |
| Storage | 16 GB | 32+ GB eMMC |
| OS | Ubuntu 22.04 | Ubuntu 22.04 |
| Kernel | 5.10 BSP | 6.1+ PREEMPT_RT |

## Verified Boards

- NanoPC T6 (FriendlyElec)
- LubanCat 8 (Waveshare)
- Radxa Rock 5B
- Orange Pi 5 / 5 Max
- Forlinx OK3588-C / FET3588-C
- IDO-SOM3588
- Dusun DSOM-3588

## Python SDK Quick Reference

```python
from rk3588_engine import RK3588InferenceEngine

engine = RK3588InferenceEngine(
    model_path="/opt/rk3588-toolkit/models/yolov5s-640-640.rknn",
    conf_threshold=0.3,
    npu_core_mask=0x07
)

detections = engine.infer(image)  # image: numpy.ndarray (H,W,3)

for det in detections:
    print(f"{det.class_name}: {det.confidence:.2f} @ {det.bbox}")

engine.release()
```

## Performance Benchmarks

| Model | Input | NPU Cores | FPS | Latency |
|-------|-------|-----------|-----|---------|
| YOLOv5s | 640×640 INT8 | 3 | 54+ | ~18ms |
| YOLOv8n | 640×640 INT8 | 3 | 40+ | ~25ms |
| ResNet18 | 224×224 INT8 | 3 | 244 | ~4ms |

## Troubleshooting

| Symptom | Check | Command |
|---------|-------|---------|
| NPU not found | Device node | `ls /dev/dri/renderD128` |
| RKNN load error | Runtime version | `ldconfig -p \| grep rknn` |
| Slow inference | NPU frequency | `cat /sys/class/devfreq/fde40000.npu/cur_freq` |
| No camera | v4l2 devices | `v4l2-ctl --list-devices` |
| OOM | CMA size | `cat /proc/meminfo \| grep Cma` |

## License

Apache 2.0. PREEMPT_RT patches follow GPLv2 (compiled on customer hardware).
