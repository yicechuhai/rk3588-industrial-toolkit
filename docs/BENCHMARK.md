# RK3588 MPP + NPU 推理性能基准 (最终报告)

> NanoPC-T6 LTS | 6.1.141内核 | RKNN 2.3.2 | MPP硬解码
> RTSP 2688x1520 H.264 → NV12 | 模型: yolov5s.rknn (INT8)
> 日期: 2026-07-03

## 流水线基准 (端到端)

| 版本 | 方案 | 解码 | 预处理 | NPU | 总延迟 | FPS | 说明 |
|------|------|------|--------|-----|--------|-----|------|
| v0 | OpenCV软解 | 35.6ms | 7.1ms | 18.6ms | 61.3ms | 13.8 | 基线 |
| v5 | MPP+DMA | <1ms | 10.4ms | 15.4ms | 25.8ms | 38.7 | +180% |
| **v7** | **MPP+cv2** | **0.2ms** | **8.7ms** | **15.4ms** | **24.2ms** | **41.2** | **当前最优** |
| v7单核 | MPP+cv2 | 0.2ms | 7.6ms | 20.9ms | 28.7ms | 34.8 | 单核 |
| v7b | YUV2RGB直转 | 0.2ms | 9.1ms | 15.4ms | 24.7ms | 40.4 | 持平v7 |
| v8 | RGA ctypes初次 | 0.2ms | 10.5ms | 14.2ms | 24.9ms | 40.1 | 格式错误 |
| v9 | GST管线缩放 | 0.1ms | 1.1ms | 29.3ms | 30.5ms | 32.7 | NPU对齐问题 |
| v10 | RGA V3 | 0.2ms | 10.2ms | 13.8ms | 24.2ms | 41.3 | ctypes开销 |

## NPU纯推理对比 (模型级别)

| 模型 | 量化 | NPU延迟 | 模型大小 | toolkit |
|------|------|---------|----------|---------|
| **yolov5s** | **INT8** | **20.3ms(三核)** | 8.3MB | v1.6.2 |
| yolov5n | FP16 | 47.1ms(三核) | 7.4MB | v2.3.2 |
| yolov5n_fp16 | FP16 | 52.0ms(三核) | 7.4MB | v2.3.2 |

## RGA 硬件加速评估

| 路径 | 微基准 | 真实流水线 | 结论 |
|------|--------|-----------|------|
| cv2 (CPU NEON) | 2.35ms | 8.7ms | ✅ 当前最优 |
| RGA ctypes V3 | 2.85ms | 10.2ms | ❌ ctypes+分配开销 |
| RGA GStreamer插件 | - | - | 📋 需C层实现 |

## 关键发现

1. **yolov5s INT8 >> yolov5n FP16** — 量化比模型大小重要3倍
2. **RGA ctypes不可行** — Python层开销抵消硬件加速,需C扩展或GStreamer插件
3. **cv2 ARM NEON已高度优化** — 在Python层是最优选择
4. **MPP硬解码几近零开销** — 0.2ms DMA直通

## 优化路线总结

- ✅ MPP硬解码 + DMA零拷贝 (v7, 41.2 FPS)
- ✅ cv2 NEON 预处理 (已是最优Python路径)
- ❌ RGA ctypes (ctypes开销 > 硬件收益)
- ❌ yolov5n FP16 (缺少INT8量化, 比yolov5s慢3x)
- 📋 GStreamer RGA插件 (C层零拷贝, 预计预处理2ms)
- 📋 INT8重量化yolov5s (用v1.6 toolkit, 目标NPU<10ms)
