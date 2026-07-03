# RK3588 OpenLab — 基准测试报告

## 测试环境

| 项目 | 配置 |
|------|------|
| 开发板 | NanoPC-T6 (FriendlyElec) |
| 芯片 | RK3588 (8核 4×A76@2.4GHz + 4×A55@1.8GHz) |
| NPU | RKNPU v2, 驱动 0.9.8, Runtime 2.3.2 |
| 内存 | 8GB LPDDR4x |
| 系统 | Debian 11 (Bullseye), Kernel 6.1.141 |
| 摄像头 | 网络摄像头 RTSP 2688×1520 H.264 |
| 模型 | YOLOv5s-640-640.rknn (INT8量化, 8MB) |

## 端到端流水线性能对比

| 版本 | 方案 | 解码 | 预处理 | NPU | 总延迟 | FPS | P95 | 提升 |
|------|------|------|--------|-----|--------|-----|-----|------|
| v0 | OpenCV软解+CPU预处理+多核NPU | 35.6ms | 7.1ms | 18.6ms | 61.3ms | 13.8 | 79.6ms | 基线 |
| v5 | MPP硬解码+CV NV12→RGB+多核NPU | 5.2ms | 7.0ms | 14.9ms | 27.1ms | 36.9 | 30.0ms | +167% |
| **v7** | **MPP硬解码+NV12+INTER_NEAREST+多核NPU** | **<1ms DMA** | **9.6ms** | **15.0ms** | **24.9ms** | **40.2** | **30.0ms** | **+191%** |

> v7 200帧稳定验证：解码0.2ms(DMA映射)、NV12→RGB+Resize 9.6ms、NPU 15.0ms

## NPU 纯推理性能

| 模型 | 输入 | NPU延迟 | 理论FPS | 备注 |
|------|------|---------|---------|------|
| YOLOv5s (INT8) | 1×3×640×640 | 14.9ms | 67 | v7实测 |
| YOLOv5s (INT8) | 1×3×640×640 | 33.3ms | 30 | 原始FP16模型 |
| YOLOv8n-det (INT8) | 1×3×640×640 | 62.0ms | 16 | - |
| YOLOv8n-pose (FP16) | 1×3×640×640 | 70.4ms | 14 | - |

## 关键技术路线

### MPP 硬件解码
- GStreamer `mppvideodec` 直接输出 NV12 (DMA-buf)
- 从 OpenCV 软解 35.6ms → MPP DMA <1ms
- 管线: `rtspsrc → h264parse → mppvideodec → NV12 → appsink`

### NV12→RGB 转换
- cv2.COLOR_YUV2BGR_NV12 + INTER_NEAREST resize
- 2688×1520 NV12 → 640×640 RGB: 9.6ms
- 待优化: RGA 硬件 CSC+Resize (预计 <3ms)

### NPU 推理
- YOLOv5s INT8, 3核全开 (core_mask=0x7)
- 稳定 15ms, P95 < 18ms — 已达 <20ms 目标 ✅

## 下一步优化 (目标 55+ FPS)

| 优化项 | 当前 | 目标 | 预计 FPS |
|--------|------|------|----------|
| RGA 硬件 NV12→RGB+Resize | 9.6ms | ~2ms | 48+ |
| YOLOv5n 轻量模型 | 15ms | ~8ms | 65+ |
| NPU 驱动升级 0.9.8→2.x | - | - | +10% |
| 320×320 输入 (低功耗) | - | ~4ms | 80+ |

## 历史数据

### v0 (2026-07-01): 原始软件流水线
| 阶段 | 耗时 | 占比 |
|------|------|:---:|
| RTSP解码 | 35.6ms | 58% |
| 缩放(2688→640) | 7.1ms | 11% |
| NPU推理 | 18.6ms | 31% |
| **总计** | **61.3ms** | **100%** |
| **FPS** | **13.8** | - |
